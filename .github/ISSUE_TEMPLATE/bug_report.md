---
name: Bug report
about: Something is broken
labels: bug
---

## Describe the bug

A clear description of what is broken and what you expected to happen.

## Steps to reproduce

1. ...
2. ...
3. ...

## Environment

- OS:
- Docker version: (`docker --version`)
- Giulia version / commit: (`curl localhost:4000/health`)
- LLM provider(s) configured:
- ArcadeDB running: yes / no

## Logs

```
docker compose logs giulia-worker --tail=50
```

Paste relevant log output here.

## Additional context

Any other information that might help -- screenshots, config snippets (redact API keys).
