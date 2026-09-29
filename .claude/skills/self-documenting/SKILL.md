---
name: self-documenting
description: Keep MOD_fish_processing's docs in sync with its code. Use after any change that adds, removes, renames, or moves a function or file; changes processing behavior, outputs, units, or L1/L2/L3 fields; adds or changes a setup.yml / metadata.PROCESS parameter; or changes what a MODvis_*/MODplot_* script or *App shows.
---

# Self-documenting MOD_fish_processing

After making a code change, update the docs it affects on the same branch, before
proposing a commit, so the docs never drift from the code. If no docs are affected,
do nothing - don't invent documentation.

Adapted from the MIT-licensed `self-documenting` skill by shivdeepak
(github.com/shivdeepak/self-documenting), tailored to this repo's docs layout and conventions.

## Where docs live (read the index first)

- `PLAN.md` - starts with an index of its sections; open only the section you need.
  Code comments cite its section numbers (`PLAN.md Section 6.2`), so never renumber them.
- `SESSION_LOG.md` - reverse-chronological history of what was built and tested.
- `docs/` - MkDocs Material site. `docs/index.md` is the landing page; `mkdocs.yml` `nav:`
  is the real table of contents.
  - `docs/workflow/` - what each script does and how to run it, by data level.
  - `docs/concepts/` - physics/math background (`index.md` lists the pages).
  - `docs/visualization/index.md` - catalog of `MODvis_*`/`*App` and `MODplot_*` scripts.
- `README.md` - short function/app list and setup.

## Checklist

After the code change, go through this and update only what the change touches:

- [ ] `docs/workflow/<step>.md` for the affected processing step: body text, plus a new
      entry in its `## History` section. History entries are append-only - add a new
      dated entry, never rewrite an old one.
- [ ] `docs/workflow/pipeline_overview.md` - function table and diagram, if a function
      was added, renamed, moved, or removed.
- [ ] `docs/concepts/*.md` - only if the physics or math changed.
- [ ] `docs/visualization/index.md` (PLAN.md Section 11's Standing rule) - for any
      added/changed `MODvis_*`/`*App`/`MODplot_*` script: short "how to use" text and an
      example image, regenerated if the output changed.
- [ ] `setup/MODunits_L*.m` - if L0-L3 fields or their units changed.
- [ ] `setup/MODsetup_metadata_field_registry.m` - if a `setup.yml` /
      `metadata.PROCESS.*` parameter was added or its default changed.
- [ ] `README.md` - function/app list and setup steps.
- [ ] `docs/references.md` - if a new paper is cited.
- [ ] `PLAN.md` - tick Section 11 items, update status text in Sections 4/6/9.
- [ ] `SESSION_LOG.md` - add a new dated entry at the top (what changed, branch, how it
      was tested). Never edit old entries.
- [ ] Docstrings - only for non-obvious intent, trade-offs, or constraints; never narrate
      what the code plainly does. Code ported from MOD_fish_lib gets a PROVENANCE section
      naming the exact source file.

## Adding, moving, renaming, or deleting

- New doc page: add it to `mkdocs.yml` `nav:` and to the section's `index.md` if it has one.
  Prefer extending an existing page over a new one; one topic per page.
- Moved/renamed/deleted page, function, or file: grep the whole repo (docs, `.m` comments
  and docstrings, `PLAN.md`) for the old name or path and fix every reference.
- Don't back-fill docs for unrelated parts of the codebase.

## Verify

- `mkdocs build --strict -d <scratchpad>/site` passes (build into the scratchpad, not `site/`).
- Commands or examples in changed docs run as written - in a sandbox copy in the scratchpad,
  never against the real `data_for_reorg` folders.
- For visual changes, render the example image and `open` it for Nicole to look at before
  proposing a commit.

## Style and commits

- Single dashes `-` only, never m-dashes. Match the surrounding doc's tone and density.
- Docs changes go on the same branch as the code. They may be split into separate,
  grouped commits.
- Never commit without Nicole approving the commit message; never push unless asked.
