/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */
import { BiliFavDetailItemModel } from '../../viewmodel/BiliFavDetail';
import { Candidate, CandidateBuckets, MusicCandidateSelector, normalizeMusicKey, normalizeMusicText } from './MusicCandidateSelector';

interface SongInfo {
  title: string;
  singer: string;
}

interface TextEntry {
  text: string;
  rawText: string;
  role: string;
  path: string;
}

interface DashPair {
  left: string;
  right: string;
  separator: string;
}

interface DashDecision {
  orientation: string;
  score: number;
}

interface BracketMatch {
  start: number;
  end: number;
  inner: string;
  strength: number;
  kind: string;
}

export class BiliMusicParser {
  private readonly candidateSelector: MusicCandidateSelector = new MusicCandidateSelector();
  private noiseKeywords: string[] = [
    'hi-res', 'hires', 'lossless', '无损音质', '无损', '音质', '4k', '8k',
    '60fps', '50fps', '120fps', '画质', '修复', '超清', '高清', '原画',
    '动态歌词', '歌词版', '歌词', '中日字幕', '中英字幕', '中文字幕',
    '音乐可视化', '官方mv', 'mv', '纯享', '完整版', '试听', '录音棚',
    '百万豪装', '百万级装备', '音乐分享', '热门歌曲', '热歌榜', 'top100',
    '合集', 'remaster', 'official music video', 'lyrics video', '字幕',
    '私藏馆', '歌曲推荐', '超燃励志', '爆火神曲', '阴暗风', '舞见', '舞者', '编舞', '韵脚检查', '封面', '视频制作', '翻译', 'b站首发'
  ];

  private nonSongValues: string[] = [
    'mv', 'official mv', 'hi-res', 'hires', '无损音质', '无损', '音乐',
    '歌曲', '新歌', '歌词', '动态歌词', '音乐可视化', '完整版', '纯享版'
  ];

  /**
   * 传入完整收藏条目，以便在横线格式方向不明确时使用 upper.name 作弱提示。
   * upper.name 只参与方向判断，不会直接作为 singer 返回。
   */
  public parse(item: BiliFavDetailItemModel): SongInfo {
    const titleText = this.normalize(item.title);
    const introText = this.preserveLineBreaks(item.intro ?? '');
    const upperName = item.upper?.name ? this.normalize(item.upper.name) : '';

    const entries: TextEntry[] = [];
    if (titleText.length > 0) {
      entries.push({
        text: titleText,
        rawText: titleText,
        role: 'mainTitle',
        path: 'title'
      });
    }
    if (introText.length > 0 && introText !== '-') {
      entries.push({
        text: this.normalize(introText),
        rawText: introText,
        role: 'description',
        path: 'intro'
      });
    }

    const candidates: CandidateBuckets = {
      titles: [],
      singers: []
    };

    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      if (entry.role === 'description') {
        // Descriptions are often long prose/lyrics. Run each extractor only
        // when the corresponding structure is actually present.
        const hasLabelCue = this.hasDescriptionLabelCue(entry.rawText);
        const hasBracket = this.hasBracketSyntax(entry.text);
        const hasDashCue = this.hasDescriptionDashCue(entry.text, hasLabelCue, hasBracket);
        if (hasLabelCue) this.extractLabels(entry, candidates);
        if (hasBracket) this.extractBrackets(entry, candidates);
        if (hasDashCue) this.extractDashPair(entry.text, entry, upperName, candidates);
      } else {
        this.extractLabels(entry, candidates);
        this.extractBrackets(entry, candidates);
        this.extractDashPair(entry.text, entry, upperName, candidates);
      }
    }

    const selectedTitle = this.candidateSelector.selectCandidate(candidates.titles, 'title', candidates);
    let selectedSinger = this.candidateSelector.selectCandidate(candidates.singers, 'singer', candidates);
    if (selectedTitle.length > 0 && normalizeMusicKey(selectedTitle) === normalizeMusicKey(selectedSinger)) {
      selectedSinger = '';
    }

    return {
      title: selectedTitle,
      singer: selectedSinger
    };
  }

  /**
   * True only for explicit music/singer metadata in descriptions.
   * A broad word such as "歌曲" is intentionally not enough: it appears in
   * ordinary prose and would defeat the fast path.
   */
  private hasDescriptionLabelCue(value: string): boolean {
    return /(歌曲名称|歌曲名|歌名|曲名|作品名|中文名|歌曲原唱|原唱歌手|歌手名|歌手\s*[:：]|演唱者|演唱\s*[:：]|vocal(?:s)?\s*[:：]|singer\s*[:：]|performer\s*[:：]|singer\s*[:：]|词曲唱(?:视)?\s*[:：]|原唱\s*(?:为|是|[:：])|使用音乐|乐曲\s*[:：]|BGM\s*[:：]|背景音乐\s*[:：]|(?:是由|由|是)\s*[^，,。；;\n]{1,45}\s*演唱|(?:^|\n)\s*(?:作词|填词|作曲|谱曲|编曲|制作人|混音)\s*[:：])/i.test(value);
  }

  private hasBracketSyntax(value: string): boolean {
    return /《[^》]{1,100}》|「[^」]{1,100}」|〈[^〉]{1,100}〉|<[^>]{1,100}>|〖[^〗]{1,100}〗|【[^】]{1,100}】|\[[^\]]{1,100}\]/.test(value);
  }

  private hasDescriptionDashCue(value: string, hasLabelCue: boolean, hasBracket: boolean): boolean {
    if (!/[-–—_]/.test(value)) return false;
    if (hasLabelCue) return true;
    // Keep short, structured credits (e.g. "Song - Singer"), but avoid
    // treating hyphens inside long prose or lyrics as metadata separators.
    if (value.length <= 120 && !/[。！？!?；;]/.test(value)) return true;
    return hasBracket && value.length <= 240 && !/[。！？!?；;]/.test(value);
  }

  private normalize(value: string): string {
    return normalizeMusicText(value);
  }

  private preserveLineBreaks(value: string): string {
    return value
      .replace(/[\u200B-\u200D\uFEFF]/g, '')
      .replace(/\u00A0/g, ' ')
      .replace(/\r\n?/g, '\n')
      .split('\n')
      .map((line: string): string => line.replace(/[\t ]+/g, ' ').trim())
      .join('\n')
      .trim();
  }

  private isNoise(value: string): boolean {
    return this.isNoiseNormalized(this.normalize(value));
  }

  private isNoiseNormalized(value: string): boolean {
    const lower = value.trim().toLowerCase();
    if (lower.length === 0) return true;
    const tokens: string[] = lower.match(/[a-z0-9]+/g) ?? [];
    for (let i = 0; i < this.noiseKeywords.length; i++) {
      const keyword = this.noiseKeywords[i].toLowerCase();
      // Latin abbreviations such as "mv" should match whole tokens, not
      // arbitrary character sequences inside an actual song title.
      if (/^[a-z0-9]+$/.test(keyword)) {
        if (tokens.includes(keyword)) {
          return true;
        }
      } else if (lower.includes(keyword)) {
        return true;
      }
    }
    return false;
  }

  private removeNoiseBlocks(value: string): string {
    let text = this.normalize(value);
    text = text.replace(/【([^】]{1,100})】/g, (all: string, inner: string): string => {
      return this.isNoiseNormalized(inner) ? ' ' : all;
    });
    text = text.replace(/〖([^〗]{1,100})〗/g, (all: string, inner: string): string => {
      return this.isNoiseNormalized(inner) ? ' ' : all;
    });
    text = text.replace(/\[([^\]]{1,100})\]/g, (all: string, inner: string): string => {
      return this.isNoiseNormalized(inner) ? ' ' : all;
    });
    text = text.replace(/『([^』]{1,100})』/g, (all: string, inner: string): string => {
      return this.isNoiseNormalized(inner) ? ' ' : all;
    });
    return text.replace(/\s{2,}/g, ' ').trim();
  }

  private isValidTitle(value: string): boolean {
    const text = this.normalize(value);
    if (text.length === 0 || text.length > 100) return false;
    if (/https?:\/\//i.test(text)) return false;
    if (/^(所属专辑|专辑|作词|作曲|编曲|演唱|歌曲时长|发行日期|主题曲|片尾曲|插曲)/.test(text)) return false;
    if (/(Hi-?Res|无损音质|动态歌词|音乐可视化|录音棚试听|百万级装备试听|B站首发|时代巡演|演唱会终场大电影)/i.test(text)) return false;
    if (/^#[^\s]+/.test(text)) return false;
    return /[A-Za-z0-9\u3040-\u30FF\u3400-\u9FFF]/.test(text) && !/^[\s.,!?;:'\"()[\]{}<>，。！？；：、“”‘’【】《》…·、—\-_/|｜~～+&@#$%^*=]+$/.test(text);
  }

  private cleanSong(value: string): string {
    let text = this.removeNoiseBlocks(value);
    const quoteTag = text.match(/^「([^」]{1,80})」\s*(.+)$/);
    if (quoteTag != null && (this.isNoise(quoteTag[1]) || quoteTag[1].length <= 4 || /\s/.test(quoteTag[1]))) {
      text = quoteTag[2].trim();
    }
    const leadingTag = text.match(/^(?:【([^】]{1,60})】|〖([^〗]{1,60})〗|\[([^\]]{1,60})\])\s*/);
    if (leadingTag != null) {
      const tag = leadingTag[1] != null ? leadingTag[1] : (leadingTag[2] != null ? leadingTag[2] : leadingTag[3]);
      if (this.looksLikeName(tag)) text = text.substring(leadingTag[0].length).trim();
    }
    const book = text.match(/《([^《》\n]{1,80})》/);
    if (book != null) {
      text = book[1];
    } else {
      text = text.replace(/[『“"'‘][^』”"'’]{5,}[』”"'’]\s*$/g, '').trim();
      text = text.replace(/[「][^」]{12,}[」]\s*$/g, '').trim();
    }
    text = text.replace(/\s+(歌曲时长|所属专辑|歌曲原唱|歌手|歌单|填\s*词|谱\s*曲|作词|作曲|编曲|制作人|混音|动态歌词)\s*[:：]?.*$/g, '');
    text = text
      .replace(/^[\s:：|｜,，;；、-]+|[\s:：|｜,，;；、-]+$/g, '')
      .replace(/\s*[（(](改编版|翻唱版|女版|男版|DJ版|Remix|remix|伴奏版|纯享版|现场版)[^）)]*[）)]\s*$/i, '')
      .replace(/\s*[（(][^）)]*(4K|8K|修复|无损|字幕|中日|中英)[^）)]*[）)]\s*$/i, '')
      .replace(/\s*(\||｜)\s*(音乐可视化|动态歌词|歌词版|官方MV|MV|Hi-?Res.*)$/i, '')
      .replace(/\s+(官方MV|歌词版MV|动态歌词|音乐可视化|百万豪装录音棚试听|百万级装备试听).*$/i, '')
      .replace(/\s*⧸\s*THE FIRST TAKE.*$/i, '')
      .replace(/\s*#.*$/g, '')
      .replace(/[♪♫]+$/g, '')
      .trim();
    return this.isValidTitle(text) ? text : '';
  }

  private cleanSinger(value: string): string {
    let text = this.removeNoiseBlocks(value);
    const leadingName = this.extractLeadingChineseSingerName(text);
    if (leadingName.length > 0) return leadingName;
    text = text
      .replace(/^.*(记得关注[^ ]*(\s+[^ ]*){0,3}|COY Music Channel|关注UP)\s*/i, '')
      .replace(/^[\s:：|｜,，;；、-]+|[\s:：|｜,，;；、-]+$/g, '')
      .replace(/^[“"'‘].*?[”"'’]\s*/g, '')
      .replace(/\s*[“"'‘].*$/g, '')
      .replace(/\s*[《「〈<].*$/g, '')
      .replace(/\s*(创作(词曲|词|曲)?|作词|填词|作曲|谱曲|编曲|制作人|制作|混音|母带|词：|曲：|作词:|作曲:).*$/g, '')
      .replace(/(共同|合作|并)+$/g, '')
      .replace(/(演唱|献唱|合唱|演绎)(的歌曲|的流行歌曲|的一首歌曲|的歌曲|歌曲)?$/g, '')
      .replace(/^(是由|由|歌曲由|音乐由|来自)+/g, '')
      .replace(/^(中国|华语|马来西亚|澳大利亚|美国|英国|日本|韩国|瑞典)\s*/g, '')
      .replace(/^(.*?)(最强厂牌|厂牌)(?=[\u3400-\u9FFF])/g, '')
      .replace(/(女歌手|男歌手|说唱歌手|歌手)\s*/g, '')
      .replace(/\s*(第\d+张专辑|专辑|全新单曲|新歌首发|新曲|新歌|主题曲|片尾曲|插曲|\bNCOP\b|\bOP\b|\bED\b|副歌|影视原声带|歌单|流派|发行日期).*$/i, '')
      .replace(/\s*(官方的?MV|Official Music Video|MV|动态歌词|歌词版|Hi-?Res|集结号吹起).*$/i, '')
      .replace(/[-–—](官方MV|MV)$/i, '')
      .replace(/\s*#.*$/g, '')
      .trim();

    if (text.length === 0 || text.length > 100) return '';
    if (/^(作品名|歌曲名称|歌曲名|歌名|曲名|中文名)\s*[:：]/.test(text)) return '';
    if (/[。！？!?\n《》「」『』【】〖〗“”"'‘’#]/.test(text)) return '';
    if (/(主题曲|片尾曲|插曲|影视原声带|私藏馆|金曲|中日字幕|中英字幕|NCOP|官方MV|Hi-Res|试听|歌词版|B站首发)/i.test(text)) return '';
    if (/^(作词|作曲|编曲|混音|制作人|所属专辑|音响|录音设备)/.test(text)) return '';
    if (this.nonSongValues.indexOf(text.toLowerCase()) >= 0) return '';
    if (!/[A-Za-z0-9\u3040-\u30FF\u3400-\u9FFF]/.test(text)) return '';
    return text;
  }

  private looksLikeName(value: string): boolean {
    const text = this.normalize(value);
    if (text.length < 2 || text.length > 60) return false;
    if (/^\d+$/.test(text)) return false;
    if (/[。！？!?\n《》「」『』【】〖〗“”"'‘’#]/.test(text)) return false;
    if (/(Hi-?Res|无损音质|动态歌词|音乐可视化|录音棚|试听|歌曲|MV|歌词版|新歌首发|主题曲|片尾曲|插曲|专辑|金曲|字幕|NCOP|官方|中国风|B站首发)/i.test(text)) return false;
    if (/^(是|由|在|新歌|主题曲|片尾曲|插曲|OP|ED|官方|视频|电影)/.test(text)) return false;
    return /[A-Za-z0-9\u3040-\u30FF\u3400-\u9FFF]/.test(text);
  }

  private addCandidate(
    target: string,
    value: string,
    score: number,
    entry: TextEntry,
    rule: string,
    buckets: CandidateBuckets
  ): void {
    const cleaned = target === 'title' ? this.cleanSong(value) : this.cleanSinger(value);
    this.addCleanCandidate(target, cleaned, score, entry, rule, buckets);
  }

  /** Insert a value that has already passed cleanSong/cleanSinger. */
  private addCleanCandidate(
    target: string,
    cleaned: string,
    score: number,
    entry: TextEntry,
    rule: string,
    buckets: CandidateBuckets
  ): void {
    if (cleaned.length === 0) return;
    if (target === 'singer' && this.isContextLikeName(cleaned) && !this.hasSafeCommaSingerList(cleaned)) return;
    const key = normalizeMusicKey(cleaned);
    if (key.length === 0) return;
    const candidate: Candidate = {
      value: cleaned,
      key: key,
      score: score,
      source: entry.path,
      rule: rule
    };
    if (target === 'title') {
      buckets.titles.push(candidate);
    } else {
      buckets.singers.push(candidate);
    }
  }

  private extractLabels(entry: TextEntry, buckets: CandidateBuckets): void {
    const source = entry.rawText;
    let match: RegExpExecArray | null = null;

    const titleRe = /(歌曲名称|歌曲名|歌名|曲名|作品名|中文名|song\s*title|song\s*name|track\s*title|track\s*name)\s*[:：]\s*([^，,。；;\n|]+)/gi;
    while ((match = titleRe.exec(source)) !== null) {
      this.addCandidate('title', match[2], 99, entry, 'explicit-title-label', buckets);
    }

    const collaborationRe = /(合作曲|合作单曲)\s*[:：]?\s*([^，,。；;\n]+)/gi;
    while ((match = collaborationRe.exec(source)) !== null) {
      const collaborationTitle = match[2].replace(/\s*(官方)?MV公开.*$/i, '').replace(/\s*(官方MV|MV|动态歌词|歌词版).*$/i, '').trim();
      this.addCandidate('title', collaborationTitle, 88, entry, 'collaboration-title-marker', buckets);
    }

    const singerRe = /(歌曲原唱|原唱歌手|歌手名|歌手|演唱者|演唱|vocal(?:s)?|singer|performer|singer)\s*[:：]\s*([^，,。；;\n|]+)/gi;
    while ((match = singerRe.exec(source)) !== null) {
      const label = match[1];
      const score = label.indexOf('原唱') >= 0 ? 77 : (/vocal/i.test(label) ? 83 : 98);
      this.addCandidate('singer', match[2], score, entry, 'explicit-singer-label', buckets);
    }

    const originalRe = /(原唱|歌曲原唱)\s*(为|是|[:：])\s*([^，,。；;\n]+)/gi;
    while ((match = originalRe.exec(source)) !== null) {
      this.addCandidate('singer', match[3], 76, entry, 'original-singer-statement', buckets);
    }

    const singerCredit = source.match(/词曲唱(?:视)?\s*[:：]\s*([^，,。；;\n]+)/);
    if (singerCredit != null) {
      this.addCandidate('singer', singerCredit[1], 91, entry, 'singer-credit', buckets);
    }

    const lines = source.split('\n').map((line: string): string => line.trim()).filter((line: string): boolean => line.length > 0);
    if (lines.length > 1 && !/[:：]/.test(lines[0]) && /^(作词|填词|作曲|谱曲|编曲|制作人|混音)\s*[:：]/.test(lines[1])) {
      const headerSinger = this.cleanSinger(lines[0]);
      const repeatsTitle = buckets.titles.some((candidate: Candidate): boolean => candidate.key === normalizeMusicKey(headerSinger));
      if (headerSinger.length > 0 && headerSinger.length <= 50 && this.looksLikeName(headerSinger) && !repeatsTitle) {
        this.addCleanCandidate('singer', headerSinger, 82, entry, 'singer-credit-header', buckets);
      }
    }

    const performerRe = /(是由|由|是)\s*([^，,。；;\n]{1,45}?)\s*演唱(的歌曲|的流行歌曲|的一首歌曲|的歌曲|歌曲|的一首)?/g;
    while ((match = performerRe.exec(source)) !== null) {
      let performer = match[2]
        .replace(/(在|于)[^，,。；;\n]*$/g, '')
        .replace(/(并|且|同时)?(创作(词曲|词|曲)?|作词|填词|作曲|谱曲|编曲|制作人|制作).*$/g, '')
        .replace(/^(著名|知名|人气|实力派)\s*/g, '')
        .trim();
      if (performer.length > 0) {
        this.addCandidate('singer', performer, 95, entry, 'natural-language-performer', buckets);
      }
    }

    const musicRe = /(乐曲|使用音乐|BGM|背景音乐)\s*[:：]\s*([^，,。；;\n]+)/i;
    const music = source.match(musicRe);
    if (music != null) {
      const credit = this.normalize(music[2]);
      const slash = credit.lastIndexOf('/');
      if (slash > 0 && slash < credit.length - 1) {
        this.addCandidate('title', credit.substring(0, slash), 94, entry, 'music-credit-title', buckets);
        this.addCandidate('singer', credit.substring(slash + 1), 86, entry, 'music-credit-singer', buckets);
      }
    }

    if (entry.role === 'mainTitle') {
      // A short leading Chinese name followed by a long narrative phrase is
      // often an uploader's singer prefix, not a complete song title.
      const leadingSinger = this.extractLeadingChineseSingerName(source);
      if (leadingSinger.length > 0) {
        this.addCandidate('singer', leadingSinger, 86, entry, 'leading-chinese-singer', buckets);
        return;
      }
      // Keep a conservative fallback, but let explicit brackets and pair parsing win.
      this.addCandidate('title', entry.text, 55, entry, 'main-title-fallback', buckets);
    }
  }

  private isContextLikeName(value: string): boolean {
    const text = this.normalize(value);
    if (text.length === 0) return true;
    if (/^(听了|听着|听这|看了|看着|这首|那首|我想|我在|我好像|好像|真的|终于|突然|原来|关于|来自|对应简介|超\d+万人|\d+万人|前奏一响|旋律爱了|还是)/.test(text)) return true;
    if (/(我好像|真的失眠|前行必有|沉醉其中|评论|火爆民谣|难免凄凉|旋律爱了|推荐大家|欢迎关注|请勿|敬请期待|神曲|曾风靡|风靡全球|全球最好听|超燃|神作)/.test(text)) return true;
    if (/(天涯明月刀|中国风|影视原声|电影主题|游戏主题)/.test(text)) return true;
    if (/[，。！？!?；;：:]/.test(text)) return true;
    const hanCount = this.hanLength(text);
    if (hanCount > 6 && /[的了着在我你他她它是有不把被才就会能要想]/.test(text)) return true;
    const latin = text.match(/[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*/g);
    return latin != null && latin.length > 4;
  }

  private extractLeadingChineseSingerName(value: string): string {
    const text = this.normalize(value);
    const match = text.match(/^([\u3400-\u9FFF]{2,3})\s+(.{3,})$/);
    if (match == null) return '';
    const candidateName = match[1];
    const tail = match[2].trim();
    if (!this.looksLikeName(candidateName) || this.isContextLikeName(candidateName)) return '';
    // A year or a parenthesized alternate title is not a singer suffix.
    if (/^(\d{2,4}|[（(『「“"'‘-])/.test(tail)) return '';
    const hasNarrativeCue = /[的了着在我你他她它是有不把被才就会能要想]/.test(tail) || /[,，。！？!?；;：:]/.test(tail);
    return this.hanLength(tail) >= 5 && hasNarrativeCue ? candidateName : '';
  }

  private hasSafeCommaSingerList(value: string): boolean {
    const parts = this.normalize(value).split(/[,，]/);
    if (parts.length < 2 || parts.length > 3) return false;
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i].trim();
      if (part.length < 2 || part.length > 45) return false;
      if (/[-–—_／/|]/.test(part) || this.isContextLikeNamePart(part) || !this.looksLikeName(part)) return false;
    }
    return true;
  }

  private isContextLikeNamePart(value: string): boolean {
    const text = this.normalize(value);
    if (/[，。！？!?；;：:]/.test(text)) return true;
    const hanCount = this.hanLength(text);
    return hanCount > 6 && /[的了着在我你他她它是有不把被才就会能要想]/.test(text);
  }

  private isLeadingBracketTitleWithShortSinger(
    item: BracketMatch,
    title: string,
    suffix: string
  ): boolean {
    if (item.kind !== 'decorative-square' || item.start !== 0) return false;
    if (title.length === 0 || suffix.length === 0) return false;
    const titleHan = this.hanLength(title);
    const suffixHan = this.hanLength(suffix);
    const latinMatch = suffix.match(/[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*/g);
    const suffixLatinWords = latinMatch == null ? 0 : latinMatch.length;
    return titleHan >= 5 && suffixHan >= 2 && suffixHan <= 4 && suffixLatinWords === 0;
  }

  private bracketMatches(text: string): BracketMatch[] {
    const result: BracketMatch[] = [];
    const opens: string[] = ['《', '「', '〈', '<', '〖', '【', '['];
    const closes: string[] = ['》', '」', '〉', '>', '〗', '】', ']'];
    const scores: number[] = [96, 86, 82, 78, 80, 80, 82];
    const kinds: string[] = ['book-title', 'corner-quote', 'single-angle', 'angle', 'decorative-square', 'decorative-square', 'square'];

    for (let i = 0; i < opens.length; i++) {
      let from = 0;
      while (from < text.length) {
        const start = text.indexOf(opens[i], from);
        if (start < 0) break;
        const close = text.indexOf(closes[i], start + 1);
        if (close < 0) break;
        result.push({
          start: start,
          end: close + 1,
          inner: text.substring(start + 1, close),
          strength: scores[i],
          kind: kinds[i]
        });
        from = close + 1;
      }
    }
    return result;
  }

  private cleanPrefix(value: string): string {
    let text = this.removeNoiseBlocks(value);
    text = text.replace(/^(【[^】]{1,80}】|〖[^〗]{1,80}〗|\[[^\]]{1,80}\])\s*/g, '');
    text = text
      .replace(/^.*(在百万豪装录音棚大声听|在百万录音棚听|百万豪装录音棚大声听|百万级装备试听|录音棚大声听|大声听|试听|歌曲推荐)\s*/i, '')
      .replace(/^(阴暗风|超燃励志|经典神作|神专|爆火神曲)[！!、\s]*/g, '');
    if (/(天涯明月刀|中国风|NCOP|主题曲|片尾曲|插曲|影视)/i.test(text)) return '';
    const parts = text.split(/[|｜]/);
    for (let i = parts.length - 1; i >= 0; i--) {
      let part = parts[i].trim();
      part = part
        .replace(/^[（(](补档|重发|转载|转发|合集)[）)]\s*/g, '')
        .replace(/\s*(官方)?MV.*$/i, '')
        .replace(/(全新单曲|新歌首发|新曲|新歌|新单|官方MV|MV公开|歌词版|纯享|Hi-?Res|无损音质|超清修复).*$/i, '')
        .replace(/(第\d+张专辑|专辑|全新单曲|新单|单曲|副歌).*$/i, '')
        .replace(/[-–—]+$/g, '')
        .trim();
      if (this.looksLikeName(part) && !/^(我的|你的|他的|她的|这首|那首|在|听|看|关于|来自|官方|视频|电影)$/.test(part) && !this.isContextLikeName(part)) return part;
    }
    return '';
  }

  private cleanSuffix(value: string): string {
    let text = this.removeNoiseBlocks(value);
    text = text
      .replace(/^[\s（(](改编版|翻唱版|女版|男版|DJ版|Remix|伴奏版|纯享版|现场版)[^）)]*[）)]?\s*/i, '')
      .replace(/^(主题曲|片尾曲|插曲|官方MV|MV|无旁白MV)\s*/i, '')
      .replace(/^([-–—|｜/／]+\s*)/g, '')
      .replace(/\s*[-–—]\s*(集结号吹起|欢迎关注|支持正版|听歌|求三连).*$/i, '')
      .replace(/\s*[-–—]\s*[‘“"'「].*$/g, '')
      .replace(/[「『“"'‘].*$/g, '')
      .replace(/\s*(官方的?MV|Official Music Video|官方MV|歌词版MV|MV|动态歌词|歌词版|Hi-?Res|无损音质|4K|8K|超清修复).*$/i, '')
      .replace(/\s*(词|作词|曲|作曲|编曲)\s*[:：].*$/g, '')
      .replace(/\s*(\||｜).*$/g, '')
      .replace(/\s*#.*$/g, '')
      .trim();
    if (/[《》「」『』【】〖〗]/.test(text)) return '';
    return this.looksLikeName(text) ? text : '';
  }

  private extractBrackets(entry: TextEntry, buckets: CandidateBuckets): void {
    const text = this.removeNoiseBlocks(entry.text);
    const matches = this.bracketMatches(text);
    const leadingTag = matches.length > 0 && matches[0].start === 0 && matches[0].kind === 'decorative-square' ? matches[0] : null;
    for (let i = 0; i < matches.length; i++) {
      const item = matches[i];
      const title = this.cleanSong(item.inner);
      if (title.length === 0 || this.isNoise(item.inner)) continue;
      if (/(专辑|album|ep|原声带|影视原声带|ost)\s*$/i.test(text.substring(Math.max(0, item.start - 12), item.start))) continue;

      const after = text.substring(item.end);
      if (/^\s*(主题曲|片尾曲|插曲|影视原声带|ost)/i.test(after)) continue;

      const before = text.substring(0, item.start);
      const prefix = this.cleanPrefix(before);
      const suffix = this.cleanSuffix(after);
      if (entry.role === 'mainTitle' && item.start === 0 && item.kind === 'decorative-square') {
        const leadingTitle = this.isLeadingBracketTitleWithShortSinger(item, title, suffix);
        const suffixSinger = suffix;
        const suffixHasExplicitTitle = /《[^》]+》|「[^」]+」|〈[^〉]+〉|<[^>]+>|\[[^\]]+\]/.test(after);
        const tagSinger = this.cleanSinger(item.inner);
        const latinSingerTag = /^[A-Za-z][A-Za-z0-9 .&'’()-]{0,40}$/.test(tagSinger) && /[\u3040-\u30FF\u3400-\u9FFF]/.test(after);
        const compoundSingerTag = /[・·、/&＆]/.test(tagSinger) && tagSinger.split(/[・·、/&＆]/).filter((part: string): boolean => part.trim().length > 0).length >= 2;
        const danceCreditContext = /(舞见|舞者|编舞|服装设计|摄影|舞蹈)/.test(entry.text);

        if (leadingTitle) {
          this.addCleanCandidate('title', title, item.strength + 5, entry, 'leading-bracket-title', buckets);
          if (suffixSinger.length > 0) this.addCandidate('singer', suffixSinger, 91, entry, 'singer-after-leading-title', buckets);
          continue;
        }
        if (tagSinger.length > 0 && !this.isContextLikeName(tagSinger) && !danceCreditContext && (suffixHasExplicitTitle || latinSingerTag || compoundSingerTag)) {
          this.addCandidate('singer', tagSinger, 90, entry, 'leading-bracket-singer', buckets);
          continue;
        }
        if (danceCreditContext && compoundSingerTag) continue;
        // Without clear evidence that the tag is an singer, retain it as a title candidate.
      }

      const prefixComesAfterLeadingTag = leadingTag != null && item.start > leadingTag.end;
      if (entry.role === 'mainTitle' && prefix.length > 0 && !prefixComesAfterLeadingTag && !/[《》「」〈〉<>]/.test(before)) {
        this.addCandidate('singer', prefix, 92, entry, 'singer-before-bracket', buckets);
      }
      if (entry.role === 'mainTitle' && suffix.length > 0) {
        this.addCandidate('singer', suffix, 89, entry, 'singer-after-bracket', buckets);
      } else if (entry.role === 'description' && /(使用音乐|乐曲|BGM|背景音乐)/i.test(entry.text) && suffix.length > 0) {
        this.addCandidate('singer', suffix, 86, entry, 'music-source-singer', buckets);
      }

      if (entry.role === 'description' && /(使用音乐|乐曲|BGM|背景音乐)/i.test(entry.text)) {
        this.addCandidate('title', item.inner, 94, entry, 'music-source-bracket-title', buckets);
      }

      let score = item.strength;
      if (entry.role === 'description') score -= 10;
      if (item.kind === 'corner-quote' && title.length > 20) score -= 14;
      if (title.length > 36) score -= 12;
      this.addCleanCandidate('title', title, score, entry, 'bracket-' + item.kind, buckets);
    }
  }

  private preparePairText(value: string): string {
    let text = this.removeNoiseBlocks(value);
    text = text
      .replace(/^.{0,100}(?:热歌榜|热门歌曲合集|热门歌曲|歌曲合集|TOP\s*\d+)[^-–—]{0,60}[-–—]\s*/i, '')
      .replace(/^.*?(COY\s*Music\s*Channel|关注UP)\s*/i, '')
      .replace(/^\s*(百万级装备试听|百万豪装录音棚试听|录音棚试听|在百万录音棚听|百万级设备试听)\s*/i, '')
      .replace(/^\s*(高清特效中字|特效中字|高清中字|中日字幕|中英字幕|中文字幕|英文字幕|官方翻译)\s*/i, '')
      .replace(/\s*[（(][^）)]*(4K|8K|修复|无损|字幕|Hi-?Res)[^）)]*[）)]/gi, '')
      .replace(/\s*(\||｜)\s*(全感官|极致卡点|Hi-?Res|无损音质|动态歌词|音乐可视化|中日字幕|中英字幕|官方MV|MV).*$/i, '')
      .replace(/\s+(百万豪装录音棚试听|百万级装备试听|动态歌词|Lyrics Video|歌词版MV|官方MV|官方歌词版MV|音乐可视化).*$/i, '')
      .replace(/[-–—]?\s*(官方MV|歌词版MV|动态歌词|音乐可视化)$/i, '')
      .replace(/\s+(作词|填词|作曲|谱曲|编曲|制作人|词：|曲：|词:|曲:)\s*[:：]?.*$/g, '')
      .replace(/\s*#.*$/g, '')
      .replace(/[♪♫]+$/g, '')
      .replace(/\s{2,}/g, ' ')
      .trim();
    return text;
  }

  private extractDashPair(value: string, entry: TextEntry, upperName: string, buckets: CandidateBuckets): void {
    const pair = this.findDashPair(value);
    if (pair == null) return;

    // These cleaned segments are reused by direction inference and insertion.
    const left = this.cleanSong(pair.left);
    const right = this.cleanSong(pair.right);
    const decision = this.inferDash(pair, entry, left, right);
    if (decision == null) return;

    let orientation = decision.orientation;
    let score = decision.score;

    // upper.name is only a weak tie-breaker for an otherwise ambiguous title pair.
    if (score <= 76 && upperName.length > 0 && entry.role === 'mainTitle') {
      const upperKey = normalizeMusicKey(upperName);
      const leftMatches = upperKey === normalizeMusicKey(pair.left);
      const rightMatches = upperKey === normalizeMusicKey(pair.right);
      if (leftMatches !== rightMatches) {
        orientation = leftMatches ? 'singer-first' : 'song-first';
        score = 78;
      }
    }

    if (orientation === 'theme-title-first') {
      this.addCleanCandidate('title', right, score, entry, 'dash-theme-title', buckets);
      return;
    }
    if (orientation === 'song-first') {
      this.addCleanCandidate('title', left, score + 1, entry, 'dash-song-first', buckets);
      if (this.looksLikeName(right)) {
        this.addCandidate('singer', pair.right, score, entry, 'dash-song-first', buckets);
      }
    } else {
      if (this.looksLikeName(left)) {
        this.addCandidate('singer', pair.left, score, entry, 'dash-singer-first', buckets);
      }
      this.addCleanCandidate('title', right, score + 1, entry, 'dash-singer-first', buckets);
    }
  }

  private findDashPair(value: string): DashPair | null {
    const text = this.preparePairText(value);
    let index = -1;
    let sepLength = 1;
    let separator = 'dash';

    const spaced = /\s+[-–—]\s+/g;
    let match: RegExpExecArray | null = null;
    while ((match = spaced.exec(text)) !== null) {
      index = match.index;
      sepLength = match[0].length;
    }

    if (index < 0) {
      const compact = /[-–—]/g;
      while ((match = compact.exec(text)) !== null) {
        const before = match.index > 0 ? text.charAt(match.index - 1) : '';
        const after = match.index + 1 < text.length ? text.charAt(match.index + 1) : '';
        if (!/[A-Za-z]/.test(before) || !/[A-Za-z]/.test(after)) {
          index = match.index;
          sepLength = 1;
        }
      }
    }

    if (index < 0) {
      const underscore = /_/g;
      while ((match = underscore.exec(text)) !== null) {
        index = match.index;
        separator = 'underscore';
      }
    }

    if (index <= 0) return null;
    const left = text.substring(0, index).trim();
    const right = text.substring(index + sepLength).trim();
    if (left.length === 0 || right.length === 0 || left.length > 90 || right.length > 90) return null;
    return { left: left, right: right, separator: separator };
  }

  private wordCount(value: string): number {
    const matches = value.match(/[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*/g);
    const latinCount = matches == null ? 0 : matches.length;
    const hanMatches = value.match(/[\u3040-\u30FF\u3400-\u9FFF]+/g);
    const hanCount = hanMatches == null ? 0 : hanMatches.length;
    return Math.max(1, latinCount + hanCount);
  }

  private hanLength(value: string): number {
    const matches = value.match(/[\u3040-\u30FF\u3400-\u9FFF]/g);
    return matches == null ? 0 : matches.length;
  }

  private hasCommaSingerList(value: string): boolean {
    const parts = this.normalize(value).split(/[,，]/);
    if (parts.length < 2 || parts.length > 3) return false;
    const first = normalizeMusicKey(parts[0]);
    const second = normalizeMusicKey(parts[1]);
    if (first === second) return false;
    for (let i = 0; i < parts.length; i++) {
      if (this.wordCount(parts[i]) < 2 && !/[.\d]/.test(parts[i])) return false;
    }
    return true;
  }

  private inferDash(
    pair: DashPair,
    entry: TextEntry,
    left: string,
    right: string
  ): DashDecision | null {
    if (left.length === 0 || right.length === 0) return null;

    if (/(电影|动画电影|电视剧|动画|游戏).*《[^》]{1,80}》.*(主题曲|片尾曲|插曲)\s*[-–—]*$/.test(pair.left)) {
      return { orientation: 'theme-title-first', score: 90 };
    }
    if (pair.separator === 'underscore') {
      return { orientation: 'song-first', score: 80 };
    }

    const leftBracket = /《[^》]+》|「[^」]+」|〈[^〉]+〉|<[^>]+>/.test(pair.left);
    const rightBracket = /《[^》]+》|「[^」]+」|〈[^〉]+〉|<[^>]+>/.test(pair.right);
    if (leftBracket && !rightBracket) return { orientation: 'song-first', score: 94 };
    if (rightBracket && !leftBracket) return { orientation: 'singer-first', score: 94 };

    const leftWords = this.wordCount(left);
    const rightWords = this.wordCount(right);
    const leftHan = this.hanLength(left);
    const rightHan = this.hanLength(right);
    const leftList = /[、/&＆;]/.test(left) || this.hasCommaSingerList(left);
    const rightList = /[、/&＆;]/.test(right) || this.hasCommaSingerList(right);
    const leftHasKana = /[\u3040-\u30FF]/.test(left);
    const rightHasKana = /[\u3040-\u30FF]/.test(right);
    const stylizedLeftSinger = /[.]/.test(left) || /[0-9]/.test(left) || /[A-Z].*[A-Z]/.test(left);
    const compactHyphenatedSinger = /[\u3400-\u9FFF]-[\u3400-\u9FFF]/.test(pair.left);
    const versionCue = entry.text.match(/([A-Z][A-Za-z0-9]+)(?:'s|’s)\s+Version/i);
    const cueMatchesRightSinger = versionCue != null && right.toLowerCase().startsWith(versionCue[1].toLowerCase());

    if (this.extractLeadingChineseSingerName(pair.right).length > 0) return { orientation: 'song-first', score: 84 };
    if (this.isContextLikeName(left) && this.looksLikeName(right)) return { orientation: 'song-first', score: 82 };
    if (/(remix|DJ版|翻唱版|伴奏版|改编版)/i.test(pair.left) && !/(remix|DJ版|翻唱版|伴奏版|改编版)/i.test(pair.right)) return { orientation: 'song-first', score: 86 };
    if (leftHasKana && /[A-Za-z]/.test(right) && rightList) return { orientation: 'song-first', score: 86 };
    if (cueMatchesRightSinger) return { orientation: 'song-first', score: 86 };
    if (rightHasKana && !leftHasKana && leftHan === 0) return { orientation: 'singer-first', score: 85 };
    if (stylizedLeftSinger && rightHan > 0) return { orientation: 'singer-first', score: 85 };
    if (compactHyphenatedSinger) return { orientation: 'singer-first', score: 83 };

    if (rightList && !leftList) return { orientation: 'song-first', score: 89 };
    if (leftList && !rightList) return { orientation: 'singer-first', score: 89 };
    if (/[A-Z].*[A-Z0-9.]/.test(left) && rightHan > 0) return { orientation: 'singer-first', score: 84 };
    if (leftHan > 4 && rightHan === 0) return { orientation: 'song-first', score: 85 };
    if (leftHan > 4 && rightHan > 0 && rightHan <= 4) return { orientation: 'song-first', score: 85 };
    if (leftWords >= 4 && rightWords <= 3) return { orientation: 'song-first', score: 88 };
    if (leftWords >= rightWords + 2 && leftWords >= 4) return { orientation: 'song-first', score: 85 };
    if (leftWords === 2 && rightWords === 1) return { orientation: 'singer-first', score: 84 };
    if (rightWords >= 3 && leftWords <= 2) return { orientation: 'singer-first', score: 86 };
    if (leftHan > 0 && rightHan > 0 && leftHan <= 4 && rightHan <= 3) return { orientation: 'singer-first', score: 76 };
    if (leftHan > 0 && rightHan === 0 && leftHan <= 4 && right.length <= 2) return { orientation: 'singer-first', score: 84 };
    if (rightHan >= 3 && leftHan === 0 && left.length <= 8) return { orientation: 'song-first', score: 84 };

    // Conventional "Singer - Song" fallback remains deliberately medium confidence.
    return { orientation: 'singer-first', score: entry.role === 'description' ? 72 : 76 };
  }


}
