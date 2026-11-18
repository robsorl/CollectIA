export type CardStatus = 'none' | 'wanted' | 'short' | 'complete' | 'dupe';

export function computeCardStatus(owned: number, wanted: number): CardStatus {
  if (owned > wanted) return 'dupe';
  if (owned === 0) return wanted > 0 ? 'wanted' : 'none';
  return owned === wanted ? 'complete' : 'short';
}
