/** Server wire record for one user-defined progress-photo tag. */
export interface ProgressPhotoTag {
  id: string;
  name: string;
  normalized_name: string;
  sort_order: number;
  created_at: string;
  updated_at: string;
}

/** Server wire record for one progress photo. */
export interface ProgressPhoto {
  id: string;
  date: string;
  tag_id: string;
  mime: string;
  bytes: number;
  sha256: string;
  updated_at: string;
}

/** Server wire record for one body-weight entry. */
export interface WeightEntry {
  id: string;
  log_date: string;
  weight_lb: number;
  source_unit: "lb" | "kg";
  created_at: string;
  updated_at: string;
}

/** Authenticated identity returned by `/auth/whoami`. */
export interface Identity {
  email: string;
  expires_at: string;
}

/** Session response returned after exchanging a one-time OAuth code. */
export interface SessionResponse extends Identity {
  token: string;
}

/** One newest-first date section rendered in the gallery. */
export interface PhotoDateGroup {
  date: string;
  photos: ProgressPhoto[];
}

/** One tag-aligned pair rendered by the comparison view. */
export interface ComparisonRow {
  tag: ProgressPhotoTag;
  left?: ProgressPhoto;
  right?: ProgressPhoto;
}
