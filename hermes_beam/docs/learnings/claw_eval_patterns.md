# Learnings: LLM Evaluation with OCR Documents

## Pattern: Ground Truth Verification Before Benchmarking

**Problem**: Benchmark expected answers may be derived from a different interpretation
of the document than what's actually in the OCR text. Running evals without verifying
ground truth wastes API calls and produces misleading failure signals.

**Solution**: Always audit expected answers by inspecting the actual data source first.

```python
# Verify expected answer is consistent with OCR
text = open(fixture_path).read()
# Search for expected value explicitly
if expected_answer not in text:
    # Recompute from OCR data directly
    recompute_answer(text, question)
```

---

## Pattern: Targeted Context Extraction for Long Documents

**Problem**: LLMs fail when given 270k-char OCR docs — they lose track of the
target table and answer from wrong sections.

**Solution**: Extract only keyword-adjacent sections (~60k chars) before sending to LLM.

**Critical**: Keywords MUST be verified against the actual document text, not assumed.

```python
def extract_relevant_sections(text, keywords, window=6000):
    positions = []
    for kw in keywords:
        pos = 0
        while True:
            idx = text.lower().find(kw.lower(), pos)
            if idx == -1: break
            positions.append(idx)
            pos = idx + 1
    # Merge overlapping windows, cap at 60k total
    ...
```

**Key insight**: Use exact phrases from the document (column headers, section titles)
not paraphrases. e.g.:
- ❌ `"silver production"` → 0 hits
- ✅ `"MONETARY STOCKS OF GOLD AND SILVER"` → 2 hits at correct position

---

## Pattern: Chain-of-Thought Prompting for Tabular QA

**Problem**: Generic prompts produce hallucinated table lookups.

**Solution**: Name exact table titles, column names, and provide explicit calculation formulas.

```
❌ Generic: "Find the silver production data and compute geometric mean"
✅ Specific: "Find table 'Silver of Specified Classifications Acquired by Mints and Assay Offices'.
              Use column 'Newly mined domestic > Own-ces'.
              Geometric mean = (v1 × v2 × v3 × v4 × v5)^(1/5)."
```

---

## Pattern: FINAL_ANSWER Tag Enforcement

Always enforce structured output with tags to make extraction reliable:

```python
system = "Always wrap your final numeric answer in <FINAL_ANSWER>NUMBER</FINAL_ANSWER> tags."
# Extraction:
m = re.search(r'<FINAL_ANSWER>\s*(.*?)\s*</FINAL_ANSWER>', response, re.DOTALL)
```

---

## Model Notes: openrouter/owl-alpha

- Follows `<FINAL_ANSWER>` tags reliably
- Good at reading markdown tables from OCR
- Shows full reasoning chain (helpful for debugging)
- Works well with step-by-step instruction prompts
- Temperature 0.0 for deterministic results
- Free tier on OpenRouter, ~25-50s per call

---

## Evaluation Architecture (No-Docker Pattern)

For benchmarks that require document reading but NOT code execution:

```
fixtures/*.txt (pre-extracted OCR)
    → keyword extraction (Python stdlib)
    → OpenRouter API call (urllib)
    → regex answer extraction
    → tolerance-based numerical comparison
```

**No pip deps, no Docker, no local models required.**
