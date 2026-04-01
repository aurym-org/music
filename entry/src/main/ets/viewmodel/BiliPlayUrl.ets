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
  baseUrl: string
}