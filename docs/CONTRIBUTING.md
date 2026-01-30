# Contributing to zigtoml

Thank you for your interest in contributing to zigtoml! This guide will help you get started.

## Getting Started

### Prerequisites

- Zig 0.15.2 or later
- Git
- GitLab account

### Setup

1. Fork the repository on GitLab
2. Clone your fork:
   ```bash
   git clone https://gitlab.com/YOUR_USERNAME/toml.git
   cd toml
   ```
3. Build and test:
   ```bash
   zig build test
   ```

## Development Workflow

### Finding Issues

Check the [issue tracker](https://gitlab.com/devnw/zig/toml/-/issues) for open issues:

- Issues labeled `priority::high` are most impactful
- Issues labeled `good-first-issue` are suitable for newcomers
- Check milestone assignments for release context

### Working on an Issue

1. Comment on the issue to claim it
2. Create a feature branch:
   ```bash
   git checkout -b feature/issue-N-description
   ```
3. Make your changes
4. Write tests for new functionality
5. Ensure all tests pass:
   ```bash
   zig build test
   ```
6. Check formatting:
   ```bash
   zig fmt --check src/ build.zig
   ```

### Submitting Changes

1. Push your branch to your fork
2. Create a Merge Request (MR) targeting `main`
3. Fill out the MR template
4. Link the related issue(s)
5. Wait for CI to pass
6. Request review

## Code Style

### Zig Style Guidelines

- Follow Zig's official style guide
- Use `zig fmt` for consistent formatting
- Keep functions small and focused
- Document public APIs with doc comments

### Documentation

- Add doc comments (`///`) to all public functions and types
- Include usage examples in doc comments
- Update README.md if API changes
- Update ROADMAP.md if adding new features

### Testing

- Write unit tests for new functions
- Add acceptance tests for user-facing features
- Test error paths, not just happy paths
- Use `std.testing.allocator` for leak detection

### Commit Messages

Use clear, descriptive commit messages:

```
feat: add streaming parser support

- Implement StreamParser struct
- Add event-based output
- Include benchmarks

Fixes #14
```

Prefixes:
- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation only
- `test:` - Adding tests
- `refactor:` - Code refactoring
- `style:` - Formatting changes
- `ci:` - CI/CD changes

## Project Structure

```
/zigtoml
  build.zig           # Build configuration
  README.md           # Project overview
  src/
    toml.zig          # Public API
    parser.zig        # TOML parser
    lexer.zig         # Tokenizer
    value.zig         # Value types
    error.zig         # Error types
    json_tagged.zig   # Tagged JSON output
    bin/
      toml_test_decoder.zig  # CLI binary
  tests/
    accept.zig        # Acceptance tests
  docs/
    ROADMAP.md        # Development roadmap
    CONTRIBUTING.md   # This file
    API.md            # API reference
```

## Testing

### Running Tests

```bash
# Run all tests
zig build test

# Run with optimization
zig build test -Doptimize=ReleaseSafe

# Check for formatting issues
zig fmt --check src/ build.zig
```

### Test Categories

- **Unit tests**: In source files, test individual functions
- **Acceptance tests**: In `tests/accept.zig`, test user scenarios
- **Fuzz tests**: (Planned) Random input testing

## Questions?

- Open an issue for bugs or feature requests
- Use discussions for questions
- Check existing issues before opening new ones

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
