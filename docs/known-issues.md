# Known Issues

- `/api/messages/{id}` and `/api/messages/stats` still need host-side validation after the recent route and queue-status fixes.
- Shutdown and background-hosting behavior still need a focused stabilization pass.
- Host validation continues to be the fastest way to find defects that do not show up in package-only review.
