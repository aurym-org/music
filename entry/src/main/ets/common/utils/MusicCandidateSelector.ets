/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

export interface Candidate {
  value: string;
  key: string;
  score: number;
  source: string;
  rule: string;
}

export interface CandidateBuckets {
  titles: Candidate[];
  singers: Candidate[];
}

/** Apply the parser's shared text normalization without changing display semantics. */
export function normalizeMusicText(value: string): string {
  return value
    .replace(/[\u200B-\u200D\uFEFF]/g, '')
    .replace(/\u00A0/g, ' ')
    .replace(/，/g, ',')
    .replace(/－/g, '-')
    .replace(/[\t\r\n]+/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim();
}

/** Normalize a candidate for equality checks without changing its display value. */
export function normalizeMusicKey(value: string): string {
  return normalizeMusicText(value).toLowerCase()
    .replace(/[\s.,!?;:'\"()[\]{}<>，。！？；：、“”‘’【】《》…·、—\-_/|｜~～+&@#$%^*=]+/g, '');
}

/** Aggregate, score and choose candidates independently of extraction rules. */
export class MusicCandidateSelector {
  public selectCandidate(items: Candidate[], target: string, buckets: CandidateBuckets): string {
    if (items.length === 0) return '';

    // Aggregate only genuinely independent input paths (title vs intro).
    const values: Candidate[] = [];
    const supports: number[] = [];
    const sources: string[][] = [];

    for (let i = 0; i < items.length; i++) {
      const candidate = items[i];
      let found = -1;
      for (let j = 0; j < values.length; j++) {
        if (values[j].key === candidate.key) {
          found = j;
          break;
        }
      }

      if (found < 0) {
        values.push({
          value: candidate.value,
          key: candidate.key,
          score: candidate.score,
          source: candidate.source,
          rule: candidate.rule
        });
        supports.push(1);
        sources.push([candidate.source]);
      } else {
        if (sources[found].indexOf(candidate.source) < 0) {
          sources[found].push(candidate.source);
          supports[found] = supports[found] + 1;
        }
        if (candidate.score > values[found].score) {
          values[found].value = candidate.value;
          values[found].score = candidate.score;
          values[found].source = candidate.source;
          values[found].rule = candidate.rule;
        }
      }
    }

    for (let i = 0; i < values.length; i++) {
      values[i].score = Math.min(100, values[i].score + Math.min(5, (supports[i] - 1) * 2));
    }

    // Candidate lists are small; insertion sort keeps the ordering explicit.
    for (let i = 1; i < values.length; i++) {
      const current = values[i];
      let j = i - 1;
      while (j >= 0 && values[j].score < current.score) {
        values[j + 1] = values[j];
        j--;
      }
      values[j + 1] = current;
    }

    let selected = values[0].score >= 50 ? values[0].value : '';
    if (selected.length === 0) return '';

    // Do not return identical strings as both song and singer when a credible
    // alternative exists for the requested side.
    const otherItems = target === 'title' ? buckets.singers : buckets.titles;
    const otherBest = this.bestKey(otherItems);
    if (otherBest.length > 0 && normalizeMusicKey(selected) === otherBest) {
      for (let i = 1; i < values.length; i++) {
        if (values[i].score >= 50 && values[i].key !== otherBest) {
          selected = values[i].value;
          break;
        }
      }
    }
    return selected;
  }

  private bestKey(items: Candidate[]): string {
    let bestScore = -1;
    let best = '';
    for (let i = 0; i < items.length; i++) {
      if (items[i].score > bestScore) {
        bestScore = items[i].score;
        best = items[i].key;
      }
    }
    return best;
  }
}
