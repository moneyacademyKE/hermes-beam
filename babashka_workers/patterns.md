# Patterns

## Environment Variable Security
When managing environment variables, consider the following patterns:

- **Do not hard-code sensitive keys**: Always use environment variables for sensitive information.
- **Use naming conventions**: Prefix or suffix sensitive keys with identifiers like 'SECRET' or 'PASSWORD' for easier identification during audits.

## Best Practices
- Regularly audit your environment variables for exposure using automated scripts.