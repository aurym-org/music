/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

export interface BiliPlayUrl {
  code: number,
  message: string,
  data: data
}

interface data {
  dash: dash
}

interface dash {
  audio: audio[]
}

interface audio {
  id: number,
  backupUrl: string[]
}