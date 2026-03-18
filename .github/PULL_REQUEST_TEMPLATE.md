## What does this PR do?

Brief description of the change and why it's needed.

## Type of change

- [ ] Bug fix
- [ ] New tool
- [ ] New API endpoint
- [ ] New LLM provider
- [ ] Documentation
- [ ] Refactor / cleanup
- [ ] Other:

## Testing

- [ ] Tests pass: `docker compose -f docker-compose.test.yml run --rm giulia-test`
- [ ] New tests added for new functionality
- [ ] Tested end-to-end with a running Giulia daemon

## Code conventions

- [ ] `mix format` run (on host, not inside Docker)
- [ ] Follows [CODING_CONVENTIONS.md](../CODING_CONVENTIONS.md)
- [ ] No `String.to_integer` without `Integer.parse`
- [ ] No `String.to_atom` from runtime values
- [ ] No bare `rescue _` swallowing errors
- [ ] `@spec` on all new public functions

## CLA

For significant contributions (new tools, architectural changes):

- [ ] I have read the Giulia CLA and agree to its terms.
  My GitHub username is **[username]** and my legal name is **[full name]**.

For minor contributions (typos, docs, small fixes): submitting this PR constitutes acceptance.
