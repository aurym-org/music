/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

export interface BiliFavDetail {
  code: number,
  message: string,
  data: data
}

interface data {
  info: info,
  medias: BiliFavDetailItemModel[],
  has_more: boolean
}

interface info {
  media_count: number
}

export interface BiliFavDetailItemModel {
  id: number,
  title: string,
  intro: string,
  upper: upper,
  cover: string,
  bvid: string,
  ugc: ugc
}

interface ugc {
  first_cid: number
}

interface upper {
  name: string
}
