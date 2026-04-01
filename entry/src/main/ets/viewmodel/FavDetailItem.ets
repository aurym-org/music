export interface FavDetail {
  code: number,
  message: string,
  data: data
}

interface data {
  medias: FavDetailItemModel[],
  has_more: boolean
}

export interface FavDetailItemModel {
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
