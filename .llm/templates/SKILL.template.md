---
name: skill-template
description: "TEMPLATE - skeleton for new skills. Copy to .llm/skills/<your-name>/SKILL.md and fill in. Do not activate or index this file directly."
metadata:
  category: feature
---

# <Skill Title>

<1-2 sentence summary of the skill's rule.>

## The Rule

<The concrete, enforceable rule. Imperative voice. What is forbidden, what
is required.>

## Why

<The failure mode this prevents, ideally with a real example from this
domain. Keep it short — depth goes in references or research.>

## How

| Situation | Do this |
| --- | --- |
| <common case> | <concrete action> |
| <edge case> | <concrete action> |

## Checklist

- [ ] <verifiable condition>
- [ ] <verifiable condition>

## Related

- Related skill reference: `<other-skill-name>` at path `../<other-skill-name>/SKILL.md`

<!-- Authoring rules (all enforced by make lint-llm):
     - name == directory name; lowercase alphanumeric + single hyphens; <= 64 chars
     - description: ONE line, <= 1024 chars, "what it does + when to use", with keywords
     - metadata.category: core | performance | feature
     - body: non-empty, <= 300 lines (soft warning at 270)
     - relative links must resolve; one H1 only -->
