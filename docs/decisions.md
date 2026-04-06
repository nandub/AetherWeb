

\## 4. Keep architectural decisions in `docs/decisions.md`



This should track the important choices already made, for example:



\- switched from async `BeginGetContext()` loop to synchronous `GetContext()` because the async path hung on host

\- added `/admin/stop`

\- foreground server is acceptable for now, but background hosting remains secondary

\- HTTP middleware is used as a MOM bridge front door, not as a broker

\- file-backed queue is the first MOM backend

\- `localhost` hostname issues were HTTP.sys prefix/ACL behavior, not route bugs



\## 5. Track active defects in `docs/known-issues.md`



This is very helpful for Codex.



Example:



\# Known Issues



\- AetherWeb.psm1 has accumulated duplicate function redefinitions across patch releases.

\- Demo scripts can drift from module parameter changes.

\- Host validation has uncovered defects faster than package-only review.

\- Need a cleanup pass to collapse duplicate definitions into one stable implementation per function.

