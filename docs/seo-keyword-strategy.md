# Search positioning

This strategy keeps search language aligned with AgentOS Workstation's actual
scope. It does not predict traffic or rankings.

## Priority queries

| Priority | Query cluster | Intent | Recommended destination |
| --- | --- | --- | --- |
| 1 | `Arch Linux workstation setup` | Evaluate a maintained workstation setup | Landing page |
| 1 | `Arch Linux Btrfs rollback`, `Arch Linux rollback after update` | Recover a broken update or design a safer update path | Dedicated recovery guide |
| 2 | `Arch Linux VPS setup`, `Arch Linux VPS onboarding` | Install or configure an Arch VPS | VPS onboarding guide |
| 2 | `encrypted Arch Linux installation`, `Arch Linux LUKS Btrfs install` | Plan a security-conscious physical install | Physical installation guide |
| 3 | `AI-assisted development Linux workstation`, `AI agent development environment Linux` | Evaluate an environment for agent-assisted development | Landing page and agent tooling guide |

Do not lead with `reproducible Arch Linux`: current results interpret that
phrase primarily as reproducible package builds. Use “reproducibly configure”
in copy while targeting “Arch Linux workstation setup” in the title and primary
description.

Do not lead with `AI development workstation`: current results are dominated by
GPU hardware vendors and model-training systems, which is not this product's
intent. Qualify AI language with “AI-assisted development” or “agent tooling.”

## Evidence and review cadence

The priorities above were reviewed against live search results on 2026-09-05:

- `Arch Linux Btrfs rollback` returns ArchWiki recovery material and multiple
  task-specific guides, indicating clear informational and problem-solving
  intent.
- `Arch Linux VPS setup` returns the ArchWiki VPS guide prominently, indicating
  established installation intent and a high-authority result to complement
  rather than imitate.
- `Arch Linux workstation setup` returns practical configuration articles,
  matching the landing page's solution-evaluation intent.
- `reproducible Arch Linux workstation` is conflated with Arch reproducible
  builds, while `AI development workstation` is conflated with GPU hardware.

## Canonical deployment target

The repository's GitHub Pages configuration reports
`https://oleg-koval.github.io/agentos/` as its HTTPS-enforced URL,
with no custom domain. Use that exact URL for the canonical, sitemap, Open Graph,
and structured-data fields. Before the first site publication the URL returns
404; do not submit the sitemap or treat the page as indexed until deployment
completes successfully.

After the site is published and indexed, use Google Search Console query and
page reports as the authority for reprioritization. Review impressions, clicks,
CTR, and average position by landing page; do not infer demand from rankings or
autocomplete alone.

## Supporting content

Add first-party HTML pages for physical installation, VPS onboarding, update
policy, boot-consistent rollback, and troubleshooting. Link them from the
landing page with descriptive anchors and keep the GitHub documentation as the
source of operational truth.
