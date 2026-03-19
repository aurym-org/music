interface FavFolderInfo {
  id?: number;
  fid?: number;
  mid?: number;
  attr?: number;
  title?: string;
  cover?: string;
  intro?: string;
  ctime?: number;
  mtime?: number;
  media_count?: number;
}

interface Owner {
  mid?: number;
  name?: string;
  face?: string;
}

interface CntInfo {
  collect?: number;
  play?: number;
  thumbUp?: number;
  thumbDown?: number;
  share?: number;
  reply?: number;
  danmaku?: number;
  coin?: number;
  vt?: number;
  playSwitch?: number;
  viewText1?: string;
}

interface Ogv {
  typeName?: string;
  typeId?: number;
  seasonId?: number;
}

interface Ugc {
  firstCid?: number;
}

interface FavDetailItemModel {
  id?: number;
  type?: number;
  title?: string;
  cover?: string;
  intro?: string;
  page?: number;
  duration?: number;
  upper?: Owner;
  attr?: number;
  cnt_info?: CntInfo;
  link?: string;
  ctime?: number;
  pubtime?: number;
  favTime?: number;
  bvid?: string;
  ogv?: Ogv;
  ugc?: Ugc;
  media_list_link?: string;
}

interface FavDetailData {
  info?: FavFolderInfo;
  medias?: FavDetailItemModel[];
  has_more?: boolean;
  ttl?: number;
}

interface FavDetail {
  code: number,
  data: FavDetailData,
  message: string,
  ttl: number
}

export { FavDetailItemModel, FavDetail };