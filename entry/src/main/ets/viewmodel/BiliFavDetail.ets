/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

/** Response model for the Bilibili favorite-resource API. */
export interface BiliFavDetail {
  code: number;
  message: string;
  data: BiliFavDetailData;
}

export interface BiliFavDetailData {
  info?: BiliFavInfo;
  medias: BiliFavDetailItemModel[];
  has_more: boolean;
}

export interface BiliFavInfo {
  media_count: number;
}

/**
 * Favorite folders may contain videos, audio entries, collections and
 * unavailable resources. Fields required only for playable videos are
 * optional here and validated before conversion to SongItem.
 */
export interface BiliFavDetailItemModel {
  id: number;
  type?: number;
  attr?: number;
  title: string;
  intro?: string;
  upper?: BiliFavUpper;
  cover?: string;
  bvid?: string;
  bv_id?: string;
  ugc?: BiliFavUgc;
}

export interface BiliFavUpper {
  name?: string;
}

export interface BiliFavUgc {
  first_cid?: number;
}
