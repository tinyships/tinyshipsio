# TinyShips

Quick whys and how-tos for doing new and interesting things with cloud-native technology.

## Structure

- `docs/` — Jekyll site source
- Posts go in `docs/_posts/` as `YYYY-MM-DD-title.md`
- Supporting files (scripts, configs) go in `docs/posts/<post-name>/`

## Running locally

```bash
podman run --rm -d -p 4000:4000 \
  -v "$(pwd)/docs:/srv/jekyll" \
  -w /srv/jekyll \
  --name tinyships-jekyll \
  mcr.microsoft.com/devcontainers/ruby:3.2 \
  bash -c "gem install jekyll minima --no-document && jekyll serve --host 0.0.0.0"
```

Site will be available at http://localhost:4000
