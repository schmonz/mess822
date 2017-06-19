# Problem statement

I send mail from my computer, tablet, and phone. Their SMTP server is my mail server's instance of [`ofmipd`, patched to support SMTP AUTH, running under `stunnel`](https://schmonz.com/2017/01/18/qmail-smtp-auth-tls-redux/). Works great.

That's usually all there is to it, even when the message I'm sending is bound for a mailing list. Except when it's one of [DJB's lists](https://cr.yp.to/lists.html). Then I have to wait to receive an automated response from the list's [`qsecretary`](https://jdebp.eu/FGA/djb-qsecretary.html) and reply to it. Then and only then does my original message get posted.

I'd like to be able to forget about the existence of `qsecretary`. [pymsgauth](http://pyropus.ca/software/pymsgauth/) solves this problem for Unix-based [MUA](https://en.wikipedia.org/wiki/Email_client)s by providing `pymsgauth-mail` to wrap `sendmail` and tag outgoing messages, and also `pymsgauth-confirm` to put in `.qmail` so it can auto-reply to the corresponding `qsecretary` notices.

Since I'm almost never sending from a Unix-based MUA, I've [added a `pymsgauth-tag` command](https://github.com/schmonz/pkgsrc-pymsgauth/commit/46bb0909c8e73cfd5cb6c7023c0f05b3dffcfe33) that can run from `qmail-qfilter`, and I've [added a `qmail-qfilter-ofmipd-queue` command](https://github.com/schmonz/pkgsrc-qmail-run/commit/437ba58d6956b65e16dd6db4e034f01a3ca30c4d) to pkgsrc `qmail-run` that'll run my choice of filters. Since my `ofmipd` also has [the QMAILQUEUE patch](https://schmonz.com/2017/05/27/qmail-submission-rewrite-headers/) applied, all my outgoing messages pass through `qmail-qfilter-ofmipd-queue` on their way into the mail queue.

There's just one problem left: `qmail-qfilter-ofmipd-queue` runs as the `ofmipd` user (in my case, `qmaild`), but `pymsgauth-confirm` runs as me, so it'll never recognize a `qsecretary` notice as a response to something I sent, and will never auto-reply.


# Proposed solution

If `ofmipd` supported SMTP AUTH _and_ ran with the Unix privileges of the authenticated user, then both `pymsgauth-tag` and `pymsgauth-confirm` would run as me, and I'd never see another `qsecretary` notice.

qmail does something like this already for POP3. `qmail-popup` runs as root and only understands the POP3 verbs `USER` and `PASS`. When it receives them, it calls `checkpassword`. If the user authenticates, it runs `qmail-pop3d` as the user.

For [OFMIP mail submission](https://cr.yp.to/proto/ofmip.html), I'd like to create a new `ofmipup` program that runs as root and only understands SMTP AUTH verbs. When it receives them, it calls `checkpassword`. If the user authenticates, it runs `ofmipd` as the user.


# Design goals

1. Make the least invasive changes to upstream `mess822`. Ideally:
	- All `ofmipd` behavior is preserved because the code is identical
	- All new behavior is provided by a new `ofmipup` program
	- TLS can keep being `stunnel`'s problem, not mine
2. Provide these configuration options for the sysadmin:
	1. AUTH required: `ofmipd` runs as the authenticated user
		- As root, `ofmipup checkpassword ofmipd`
	2. AUTH optional: `ofmipd` runs as the default user (e.g., `qmaild`) unless authenticated
		- As root, `ofmipup -u qmaild checkpassword ofmipd`
	3. AUTH unavailable: `ofmipd` runs as it always has
		- As qmaild, `ofmipd`


# Implementation steps

I'm going to try to get there like so:

1. Characterize upstream `ofmipd`'s behaviors with automated tests
    - the verbs it offers
    - how it always relays, regardless of `RELAYCLIENT`
2. Apply John Levine's SMTP AUTH patch (that I'm already using)
3. Add more characterization tests around AUTH behaviors
    - how some verbs now reject unless `RELAYCLIENT` is set
    - how SMTP AUTH causes `RELAYCLIENT` to be set
4. Write shell-level tests for what I want to happen
    - `ofmipd` by itself does not offer SMTP AUTH
    - `ofmipd` by itself is an open relay
    - `ofmipup` knows and rejects non-AUTH verbs
        - `530 Authentication required (#5.7.1)`
    - `ofmipup` accepts AUTH verbs
    - `ofmipup` passes/fails checkpassword when it should
    - `ofmipup` execs `ofmipd` as the authenticated user
5. Make them pass
6. Minimize diffs against
    - Stock mess822
    - The SMTP AUTH patch
    - qmail-popup
7. That's a spike, fam!
8. Test-drive ofmipup from scratch, including such concerns as:
    - it's a program
    - it exits nonzero without the right command-line args
    - it responds to HELP with a permalink to schmonz.com
    - when auth succeeds, we're talking to the kid from now on
    - when auth fails, we're still talking to the parent
    - when mail is submitted, it goes into the queue
    - when mail is submitted, it looks just like it would with the patch
    - when the kid exits 0, parent silently disconnects
    - when the kid exits with checkpassword codes, tempfail
    - when the kid exits with ofmipd codes that matter, fail
    - when the kid exits with ofmipd codes that don't matter, parent silently disconnects

XXX standalone `ofmipd` passes same tests as it did in earlier git
XXX standalone `ofmipd` matches upstream, plus slight awareness of `ofmipup`
XXX TCPREMOTEINFO TCPREMOTEIP and where they go in messages

<https://en.wikipedia.org/wiki/SMTP_Authentication#Details>
<http://cr.yp.to/smtp/client.html>

# How to evaluate this code

Compare against:

- Stock mess822:
    - one-line patch to `ofmipd`, no change in behavior
    - XXX TCPREMOTEINFO?
    - new program, use if you want to require auth before relaying
    - doesn't do much good by itself, other than maybe qmail design harmony
    - does do good in conjunction with the QMAILQUEUE patch (applies cleanly?):
      on submitted mail, run arbitrary administrator-approved filters
      with the privileges of the submitting user (assuming Unix auth,
      DJB's original checkpassword or perhaps checkpassword-pam)
- SMTP AUTH patch: less code, more isolated, functionally identical (or nearly so)
- qmail-popup: very similar
    - popup dies on auth failure
    - seems antisocial to do this in SMTP, and the patch doesn't, so we don't

As `ofmipup`, if I'm asked for...

- **QUIT**? Exit
- **HELO/EHLO/HELP**? Respond OK
- **MAIL/RCPT/DATA/FLOOF**? Respond not-OK
- **AUTH**? `fork()` and `wait()` for exit code
    - 0? OK, success in AUTH and `ofmipd` wants us to quit
    - 1? `checkpassword` says username/password no good
    - 2? `checkpassword` called wrong
    - 3? `ofmipd` exited some sort of nonzero
    - 111? `checkpassword` temporary problem
    - Other nonzero? Unknown kind of not-OK

As `ofmipd`, iff I'm called from `ofmipup`...

- `OFMIPUP` is present in the environment (empty or any other value)
- Instead of banner, print `235 ok`

Where `qmail-popup` runs as root and exits on **AUTH** failure (that must have been fine for POP3), `ofmipup` runs as root and exits only on **QUIT**, or if its child `ofmipd` has **QUIT**.

Mitigations for me writing in C, in DJB-style C, adapting someone else's patch, running code as root:

- The only decisions `ofmipup` knows how to make are whether to run `checkpassword` and which parameters to pass to it
- Each new client connection gets a fresh `ofmipup`

## Security concerns: Design

This might be an unsafe design.

stock `ofmipd` doesn't do SMTP AUTH at all. It runs as whatever user the sysadmin started it as, relays for anyone who can connect, does whatever address rewriting it's configured to do, and injects messages into the queue.

`ofmipd` with the SMTP AUTH patch is the same, plus it allows relaying from users who have authenticated with whatever `checkpassword` the sysadmin chose. I chose DJB's that works with system passwords. In my configuration, because it's run by the `qmaild` user, it has to be setuid-root.

The ofmipd SMTP AUTH patch also includes the QMAILQUEUE patch, which means that if the sysadmin chose to set QMAILQUEUE, ofmipd will call that program instead of `qmail-queue`. If that program runs a set of filters before calling the real `qmail-queue`, those filters are run as whatever user the sysadmin started `ofmipd` as.

My proposed change is that `ofmipd` runs iff a user has authenticated, and then runs as that user. In conjunction with the sysadmin having set QMAILQUEUE, any filters configured by the sysadmin will run as before, except with the privileges of the authenticated user.

The only way users could configure their own arbitrary filters would be for the sysadmin to write a QMAILQUEUE wrapper that knows how to do that -- say, by looking in `$HOME/.ofmiprc` and running whatever's in there.

The risk from that may or may not be obvious, but I don't think there's a way to incur it without some such enabling action by the sysadmin. Unless I'm missing something.

As an attacker, if I can SMTP AUTH as somebody, I can probably IMAP as them. IMAP servers run filters too. My Dovecot config has some very basic Sieve filters that run as whoever's mailbox it is. `qmail-local` always runs as the user being delivered to. An attacker who can figure out someone's running an old version of `procmail` can probably get plenty of access.

Unless I do a bad job, I suspect extracting the SMTP AUTH to its own program -- even one that runs as root -- doesn't increase the attack surface, and may even decrease it. Unless a sysadmin does a bad job, I suspect running `ofmipd` with the privileges of the authenticated user helps, and probably doesn't hurt. (Unless, again, I'm missing something!)

> I didn't realize it was limited (by default) to specific filters specified by the sysadmin. That is much better. But it is still a broadening of the attack surface: those scripts would have been run (before) as a single very-limited user; now they will be run as any arbitrary real user. So a script with a vulnerability in it now has much greater reach than it did before.
>
> As always, security is a tradeoff. Maybe this is a tolerable tradeoff :)
>
> I agree that extracting AUTH to its own program seems sane. Running it as root is clearly riskier, but I agree that the risk is probably offset by the simplification of what the program does. 


## Security concerns: Implementation

I might do a bad job. These factors mitigate my fear:

1) Probably mostly refactoring, not writing new code
2) For new code, can probably steal a lot from qmail
3) By copied-from-qmail design, the code that runs as root has one small job to do
4) Given how ofmipd works, I bet I can easily get automated tests around it before I start
