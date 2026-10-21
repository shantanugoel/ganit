# AI experience visual references

Design references for AI as part of the calculator, drafted 2026-10-20. These
are design references, not screenshots of an implemented Ganit feature.

- [Implementation plan](../../plans/ai-native.md)
- [Click-through prototype](prototype.html)
- [Flow, UI shapes and key decisions](index.html)

## Using them

Open `prototype.html` in a modern browser. The nine scenario chips in the
right rail jump between flows; `→` / `←`, and the blue buttons inside the
panels, step through each flow. Clicking a thing that looks clickable in the
window (the `Ask` chip, `Ask Ganit…`, `Apply`) advances the story. Each step
states what you do, what changes, and what the model and Ganit are doing.

Scenarios: plain Ganit with AI absent · words to an editable calculation ·
prose to a model with its guesses marked · transforming a selection · rejected
model output and automatic repair · one clarification · an AI-supplied fact
with provenance · explain and fix · no model configured.

Open `index.html` for the one-operation-four-outcomes flow map, the four UI
shapes, the decision and alternatives tables, and the smallest v1.

## What these files do not do

Neither file parses source, calls the Ganit engine, or sends a network
request. Sheet content, answers, validation results and repair outcomes are
fixed data written to demonstrate states, including failures. Styles imitate
`VisualStyle` tokens closely enough to judge placement, hierarchy, chrome and
provenance; production must use the real tokens, real system colors, and the
existing overlay and popover drawing. The plan defines production behavior,
the outcome contract, removals, verification gates and milestones.
