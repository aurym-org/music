/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

export interface BiliWbiInfo {
  imgKey: string,
  subKey: string,
  time: number
}

export interface BiliWbiResponse {
  data: data
}

interface data {
  wbi_img: wbi_img
}

interface wbi_img {
  img_url: string,
  sub_url: string
}
