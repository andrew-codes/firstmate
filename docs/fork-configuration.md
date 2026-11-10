# Fork configuration

This page lists the settings that only this fork has.
Each is optional, and nothing changes until you set it.
Config files live in your firstmate home's `config/` directory.
See [FORK.md](../FORK.md) for what the fork adds.

## Unanswered review-comment reminder

Set a reply age to be told when a review comment on a pull request you own goes unanswered.
It works for GitHub and, in this fork, Bitbucket Cloud pull requests.
Without a value the reminder stays off.

| Setting | What it controls |
| --- | --- |
| `config/contributions-reply-age` | How long a comment may sit unanswered before you are told, as a positive number of seconds. The first line that is not a comment is used. |
| `FM_CONTRIBUTIONS_REPLY_AGE` | The same value as an environment variable. When set, it wins over the file. |
| `config/contributions-ignore-commenters` | Comma-separated names whose comments are never counted as unanswered, such as a pipeline bot. |
| `FM_CONTRIBUTIONS_IGNORE_COMMENTERS` | The same list as an environment variable. When set, it wins over the file. |

The files survive restarts, so the setting is not lost when supervision is re-armed.
An invalid value in a file is refused with a message naming the file.

```sh
# Tell me when a comment has gone unanswered for 30 minutes, ignoring ci-bot.
echo 1800 > config/contributions-reply-age
echo ci-bot > config/contributions-ignore-commenters

# Or set them in the environment that starts firstmate, which wins over the files.
export FM_CONTRIBUTIONS_REPLY_AGE=1800
export FM_CONTRIBUTIONS_IGNORE_COMMENTERS=ci-bot
```

## Jira status transitions

`config/jira-status-transitions` turns on Jira status follow-through for the projects it lists.
Without the file nothing is read or written from Jira.
Each line names a project by its clone directory under `projects/`, then its settings:

| Setting | What it controls |
| --- | --- |
| `site=<site>` | Required. The Jira site to use. |
| `max-behind=<n>` | Optional. How many commits a pull request may trail its target branch and still count as ready for Review. Not checked when omitted. |
| `ignore-commenters=<names>` | Optional. Comma-separated commenters, such as pipeline bots, whose threads do not need a reply before the pull request counts as ready. |

The Jira work item is found from the key in the task's branch name, such as `fm/PROJ-4240-fix-login`.
A task whose branch has no key is left alone.

```text
# config/jira-status-transitions
my-app site=my-team max-behind=20 ignore-commenters=ci-bot
```

| Setting | What it controls |
| --- | --- |
| `FM_JIRA_TIMEOUT` | Optional environment variable. Seconds to wait for each Jira call before giving up with a warning. Defaults to 30. |

```sh
FM_JIRA_TIMEOUT=60 bin/fm-jira-transition.sh ready my-task-id
```
