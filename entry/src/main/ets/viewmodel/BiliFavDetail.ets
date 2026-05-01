export interface BiliFavDetail {
  code: number,
  message: string,
  data: data
}

interface data {
  medias: BiliFavDetailItemModel[],
  has_more: boolean
}

export interface BiliFavDetailItemModel {
  id: number,
  title: string,
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
