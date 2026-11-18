import { describe, expect, it } from 'vitest';
import { computeCardStatus } from './status';

describe('computeCardStatus', () => {
  it('aucune possession, aucune envie', () => {
    expect(computeCardStatus(0, 0)).toBe('none');
  });

  it('manquante : souhaitée mais possédée = 0', () => {
    expect(computeCardStatus(0, 1)).toBe('wanted');
    expect(computeCardStatus(0, 3)).toBe('wanted');
  });

  it('incomplète : possédée < souhaitée, mais ≠ 0', () => {
    expect(computeCardStatus(1, 2)).toBe('short');
  });

  it('complète : possédée = souhaitée', () => {
    expect(computeCardStatus(2, 2)).toBe('complete');
  });

  it('doublon : possédée > souhaitée (y compris souhaitée = 0)', () => {
    expect(computeCardStatus(3, 1)).toBe('dupe');
    expect(computeCardStatus(2, 0)).toBe('dupe');
  });
});
