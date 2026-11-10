# What this fork adds

This is a fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate), maintained by Andrew Smith.
It does everything upstream does and adds the capabilities below.
It is current with upstream through commit `913bb7a7` (2026-11-09).

## What you gain

| Feature | What you get |
| --- | --- |
| Bitbucket Cloud pull requests | Work whose pull request lives on Bitbucket Cloud is tracked like a GitHub pull request or GitLab merge request. Firstmate notices when it merges and shows its state in crew status, using your own signed-in `twg`. You still merge it yourself on Bitbucket. |
| Unanswered Bitbucket review comments | You are told when a reviewer's comment on a Bitbucket pull request goes unanswered for a time you choose. Review-bot comments count only when attached to a line of code, and you can skip named commenters. |
| Bitbucket pull request alerts | Optional alerts when a Bitbucket pull request has a merge conflict, a failed merge check, a failed build, or an unresolved review thread. Firstmate only tells you and never changes the pull request. |
| Open pull request with nobody watching | You are told once when a pull request is still open but nothing is monitoring it any more, for example after the no-mistakes daemon restarted, so it does not sit unnoticed. |
| Jira status that follows the work | A task's Jira work item moves to In Progress when work starts, Review when its pull request is ready, and Done when it merges. A Jira failure never blocks your work. |

## Configuration

The fork adds a few settings, all optional and off by default.
[docs/fork-configuration.md](docs/fork-configuration.md) lists each one with what it controls and a real example.
