# Issue tracker: Jira

Issues and specs live in Jira project `EPMDEDP`. Use the `mcp__mcp-atlassian__jira_*` tools. No `gh issue` calls: the GitHub repo has no issue tracker in use.

## Conventions

- **Labels**: every issue a skill creates carries `krci-substrate` and `AI-generated`.
- **Title**: starts with `krci-substrate: `.
- **Spec**: issue type `Task` with `{"epic_link": "<epic key>"}` in `additional_fields`. Epic `EPMDEDP-17520` unless the user names another.
- **Ticket**: issue type `Sub-task` with `{"parent": "<spec key>"}` in `additional_fields`. Sub-tasks have no children.
- **Create**: `jira_create_issue` with `project_key: EPMDEDP`, Markdown `description`, `additional_fields: {"labels": ["krci-substrate", "AI-generated", ...]}`.
- **Read**: `jira_get_issue` with `include: comments`. Epic Link is `customfield_14500`; read it with `fields: customfield_14500`.
- **List**: `jira_search`, JQL `project = EPMDEDP AND labels = krci-substrate AND statusCategory != Done AND status != "In review"`, plus `labels = <triage label>` or `parent = <spec key>`. Pass `fields: summary,status,assignee,issuelinks`; the default fields include every description and overflow the tool output. Read a description with `jira_get_issue` for the picked ticket only.
- **Blocking**: `jira_create_issue_link` with `link_type: Blocks` (id 12300): the blocker `blocks` the child. After the first link of a session, `jira_get_issue` the child and confirm it shows `is_blocked_by <blocker>`; if reversed, swap `inward_issue_key` and `outward_issue_key` for the rest of the session. Remove a wrong edge with `jira_remove_issue_link`, taking the `link_id` from the issue's `issuelinks`. Also put `Blocked by: <KEY>-<n>, <KEY>-<n>` as the first line of the child description; a blocker can be in any Jira project.
- **Count open blockers**: read each key in the `Blocked by:` line and the `is_blocked_by` links; a ticket is startable when every blocker is `In review` (its PR is merged) or has `statusCategory = Done`.
- **Comment**: `jira_add_comment`.
- **Description edit**: `jira_update_issue` replaces the whole description; send the full text with only the changed lines edited. See **Jira formatting**.
- **Labels update**: `jira_update_issue` with `fields: {"labels": [...]}`. Send the full list; it replaces the existing labels.
- **Resolution Done (required)**: every `jira_transition_issue` to a status in the Done category passes `fields: '{"resolution": {"name": "Done"}}'`. After the transition, `jira_get_issue` with `fields: status,resolution` and confirm resolution is Done. A Done-category status with an empty resolution is an error: fix it in the same session.
- **Close** (not done through a PR: `wontfix`, duplicate, obsolete): comment the reason, then `jira_get_transitions` and `jira_transition_issue` to a status in the Done category, with resolution Done.
- **Commit titles**: format in `CLAUDE.md` Conventions; `EPMDEDP-<n>` is the ticket being worked.
- **Issue references**: an `EPMDEDP-<n>` prefix in a commit title is the issue reference. Fetch it from Jira, not as a GitHub `#<n>`.
- **Where keys go**: commit titles, branch names and PR bodies. Never in templates, values, comments or other docs.

## Jira formatting

Descriptions and comments go in as Markdown; the server stores Jira wiki markup and gives it back as Markdown on read. Each round trip converts again.

- Inline code holds no `{`, `}`, `[`, `]`: wiki reads them as macro and link syntax. Name the thing instead: "the Helm include of the helper", "value `caPools.source`".
- `+`, `*`, `_`, `^`, `~`, `-` between words are wiki markup (underline, bold, italic, sup, sub, strike). Write "plus", "times", or put the expression in inline code.
- Bold: `**word**`, closed. `**word*` turns into italics.
- Nested list item: two spaces, then `-`.
- Code fence: no blank line before the closing fence; each round trip adds one.
- Fenced blocks: no `#` comment lines, heredocs, `->` or `[N]` indices.
- After an update, read the returned markup: `{{…}}` code, `*…*` bold, `h2.` headings, `**` / `#` lists.

## Pull requests

Code review happens in GitHub pull requests on `KubeRocketCI/krci-substrate` through the `gh` CLI. Issues stay in Jira.

- **Title**: commit-title format.
- **Body**: the `/pr` template (Summary, Evidence, Merge Danger), preceded by one line `Jira: EPMDEDP-<n>` (the ticket, or the spec for a PR that covers a whole spec).
- **Draft PR**: allowed for a spec built on one integration branch.
- **After merge**: no Jira change. A ticket can have several PRs; a person moves its status.
- **PRs as a request surface: no.** `/triage` reads Jira issues only.

## When a skill says "publish to the issue tracker"

Create a Jira issue as above.

## When a skill says "fetch the relevant ticket"

`jira_get_issue` with `include: comments`.

## Wayfinding operations

Used by `/wayfinder`. The map is one issue; tickets are its sub-tasks.

- **Map**: a `Task` labelled `wayfinder:map`, `krci-substrate` and `AI-generated`, with the effort's epic link; its description holds Destination / Notes / Decisions-so-far / Not yet specified / Out of scope.
- **Child ticket**: a `Sub-task` of the map, labelled `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`).
- **Blocking**: as under Conventions.
- **Frontier query**: JQL `parent = <map> AND statusCategory != Done AND status != "In review" AND assignee is EMPTY ORDER BY created ASC`; drop tickets with an open blocker; first wins.
- **Claim**: `jira_update_issue` with `fields: {"assignee": "<user>"}`, the session's first write.
- **Resolve**: comment the answer, transition to Done with resolution Done, append a pointer (gist + key) to the map's Decisions-so-far.
