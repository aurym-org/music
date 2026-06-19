/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */
import { SongInfo } from "../../viewmodel/SongData";

export class BiliMusicParser {
  private noiseKeywords: string[] = [
    '4k', 'hi-res', 'hires', '无损', '超燃', '励志', '高清',
    '1080p', '修复', '珍藏', '原画', '最高音质', '全网最高音质',
    '60fps', '120帧', '动态歌词', '歌词版', '完整版', '单曲',
    '全新单曲', '伴奏', '试听', '官方mv', 'mv', '补档',
    '中英', '中日', '字幕', '私藏馆', '百万', '录音棚',
    '装备试听', '装备听', '大声听', '听歌', '无损音质',
    '超燃励志', '60帧', '4k60fps', 'hi-res无损', '音质'
  ];

  public parse(title: string, intro: string): SongInfo {
    const introResult = this.extractFromIntro(title, intro);
    if (introResult && introResult.singer && introResult.title ) {
      return {
        singer: this.cleanSingerFromIntro(introResult.singer),
        title: introResult.title,
        confidence: 0.95
      };
    }

    const preCleaned = this.preClean(title);
    const bracketResult = this.extractBracketed(preCleaned);
    if (bracketResult) {
      return { singer: bracketResult.singer, title: bracketResult.title, confidence: 0.85 };
    }

    const cleaned = this.deepClean(preCleaned);

    let result = this.parseBook(cleaned);
    if (result) return this.validate(result, intro, 0.85);

    result = this.parseBracketSong(cleaned);
    if (result) return this.validate(result, intro, 0.8);

    result = this.parseSingerBracket(cleaned);
    if (result) return this.validate(result, intro, 0.8);

    result = this.parseSongFirstBracket(cleaned);
    if (result) return this.validate(result, intro, 0.75);

    result = this.parseEnglishDash(cleaned);
    if (result) return this.validate(result, intro, 0.8);

    result = this.parseSeparator(cleaned);
    if (result) return this.validate(result, intro, 0.65);

    const singerFromIntro = this.extractSingerOnlyFromIntro(intro);
    if (singerFromIntro) {
      return {
        singer: this.cleanSingerFromIntro(singerFromIntro),
        title: cleaned || title,
        confidence: 0.5
      };
    }

    return { singer: '', title: cleaned || title, confidence: 0.1 };
  }

  private preClean(text: string): string {
    let t = text;
    t = t.replace(/【([^】]+)】/g, (match: string, content: string) => {
      const lower = content.toLowerCase();
      if (this.noiseKeywords.some(kw => lower.includes(kw.toLowerCase()))) {
        return '';
      }
      return match;
    });
    t = t.replace(/(?:在)?百万(?:豪装)?录音棚(?:大声听|听)?/g, '');
    t = t.replace(/百万级装备试听/g, '');
    t = t.replace(/百万级装备听/g, '');
    t = t.replace(/(?:官方\s*)?MV/g, '');
    t = t.replace(/#[^\s]*/g, '');
    t = t.replace(/^[－—–\-|｜\s]+/, '');
    return t.trim().replace(/\s{2,}/g, ' ');
  }

  private extractBracketed(text: string): SongInfo | null {
    let m = text.match(/^【([^】]+)】\s*[\[《]?([^\]》]+)[\]》]?\s*$/);
    if (m) {
      const singer = m[1].trim(), title = m[2].trim();
      if (!this.isNoiseText(singer) && !this.isNoiseText(title)) return { singer, title };
    }
    m = text.match(/^【([^】]+)】\s*([\w\u4e00-\u9fff&·]{1,12})\s*$/);
    if (m) {
      const title = m[1].trim(), singer = m[2].trim();
      if (!this.isNoiseText(title) && !this.isNoiseText(singer)) return { singer, title };
    }
    m = text.match(/^([\w\u4e00-\u9fff&·]{1,12})【([^】]+)】/);
    if (m) {
      const singer = m[1].trim(), title = m[2].trim();
      if (!this.isNoiseText(singer) && !this.isNoiseText(title)) return { singer, title };
    }
    return null;
  }

  private deepClean(text: string): string {
    let t = text;
    t = t.replace(/【[^】]+】/g, '');
    t = t.replace(/完整版|动态歌词版?|歌词版|单曲|全新单曲|伴奏|试听|Hi-?Res无损|无损音质/gi, '');
    t = t.replace(/[（(][^）)]*?(?:动态歌词|Lyrics|无损|4[Kk]|Hi-?Res|试听|歌词版|MV|字幕)[^）)]*[）)]/gi, '');
    t = t.replace(/[『「][^』」]*[』」]/g, '');
    t = t.replace(/“[^”]{5,}”/g, '');
    return t.replace(/\s{2,}/g, ' ').trim();
  }

  private extractFromIntro(title: string, intro: string): SongInfo | null {
    if (!intro || intro === '-') return null;

    const songLine = intro.match(/歌名\s*[:：]\s*([^\n]+)/);
    const singerLine = intro.match(/(?:演唱|歌手|主唱)\s*[:：]\s*([^\n\/\,，；;（(]+)/);
    if (songLine && singerLine) {
      return {
        singer: singerLine[1].trim(),
        title: songLine[1].replace(/^《|》$/g, '').trim()
      };
    }

    let m = intro.match(/《([^》]+)》\s*(?:是由|是|由)\s*([^，,（(]+?)\s*(?:演唱|主唱|唱的|所唱)/);
    if (m) {
      let singer = m[2].trim();
      if (singer.length > 15 || /作词|作曲|编曲/.test(singer)) {
        const pure = intro.match(/(?:演唱|歌手)\s*[:：]\s*([^\n\/\,，；;（(]+)/);
        if (pure) singer = pure[1].trim();
        else return null;
      }
      return { singer, title: m[1].trim() };
    }

    if (singerLine) {
      const singer = singerLine[1].trim();
      const book = title.match(/《([^》]+)》/);
      if (book) return { singer, title: book[1].trim() };
      const cleaned = this.deepClean(title);
      const parts = cleaned.split(/[-_－—~～|\s]+/).filter(Boolean);
      if (parts.length > 0) return { singer, title: parts[0] };
    }
    return null;
  }

  private extractSingerOnlyFromIntro(intro: string): string | null {
    if (!intro || intro === '-') return null;
    const m = intro.match(/(?:演唱|歌手|主唱)\s*[:：]\s*([^\n\/\,，；;（(]+)/);
    return m ? m[1].trim() : null;
  }

  private cleanSingerFromIntro(name: string): string {
    if (!name) return name;
    name = name.replace(/^(歌手|主唱|演唱|歌者|唱作人)\s*/i, '');
    name = name.replace(/\s*(乐队|组合|合唱团|乐团|团)$/, '');
    name = name.replace(/(创作|填词|谱曲|作词|作曲|编曲|制作|和声|混音|录音|母带).*/g, '');
    name = name.replace(/^[a-zA-Z\u4e00-\u9fff]+歌手\s*/i, '');
    return name.trim();
  }

  private parseBook(cleaned: string): SongInfo | null {
    const match = cleaned.match(/(.*?)《([^》]+)》(.*)/);
    if (!match) return null;
    const title = match[2].trim();
    let before = match[1].trim();
    const after = match[3].trim();
    let singer: string | null = null;

    // 修复：如果 before 包含“|”，取第一部分（如“任然 | 我的”）
    if (before && before.includes('|')) {
      before = before.split('|')[0].trim();
    }
    // 修复：去掉尾随的符号（如“王菲-”）
    before = before.replace(/[-_－—~～|｜\s]+$/, '');

    if (before && before.length <= 8 && !/^[_\-\s~～+、&|]+$/.test(before) && !this.isInvalidSingerName(before)) {
      if (before.length === 1 && !/[\w\u4e00-\u9fff]/.test(before)) {
        singer = null;
      } else {
        singer = before;
      }
    }

    if (!singer && after) {
      const afterMatch = after.match(/^[-_~～\s|]*([^\s"'『【《\-\s~～，,]+)/);
      if (afterMatch && !this.isInvalidSingerName(afterMatch[1])) {
        singer = afterMatch[1].trim();
      }
    }
    return { singer: singer || '', title };
  }

  private parseBracketSong(cleaned: string): SongInfo | null {
    const match = cleaned.match(/[\[『]([^\]』]+)[\]』]/);
    if (!match) return null;
    const title = match[1].trim();
    const rest = cleaned.replace(match[0], '').trim();
    const singerBracket = rest.match(/^【([^】]+)】/);
    if (singerBracket) return { singer: singerBracket[1].trim(), title };
    const singerMatch = rest.match(/^[^\-_－—~～|\s]+/);
    return { singer: singerMatch ? singerMatch[0].trim() : '', title };
  }

  private parseSingerBracket(cleaned: string): SongInfo | null {
    const match = cleaned.match(/^【([^】]+)】\s*(.+)/);
    if (!match) return null;
    const singer = match[1].trim();
    let rest = match[2].trim();
    const songBracket = rest.match(/[\[《]([^\]》]+)[\]》]/);
    if (songBracket) return { singer, title: songBracket[1].trim() };
    const parts = rest.split(/[-_－—~～|]+/).map(s => s.trim()).filter(Boolean);
    if (parts.length > 0) return { singer, title: parts[0] };
    return null;
  }

  private parseSongFirstBracket(cleaned: string): SongInfo | null {
    const match = cleaned.match(/^【([^】]+)】\s*([\w\u4e00-\u9fff&·]{1,12})(?:\s|$)/);
    if (!match) return null;
    const title = match[1].trim(), singer = match[2].trim();
    if (this.noiseKeywords.some(kw => singer.toLowerCase().includes(kw.toLowerCase()))) return null;
    return { singer, title };
  }

  private parseEnglishDash(cleaned: string): SongInfo | null {
    const match = cleaned.match(/^([A-Za-z0-9\s,.'&()]+)\s*[-–—]\s*([A-Za-z0-9\s,.'&()]+)$/);
    if (!match) return null;
    return { singer: match[2].trim(), title: match[1].trim() };
  }

  private parseSeparator(cleaned: string): SongInfo | null {
    const segments = cleaned.split(/[-_－—~～|｜]+/).map(s => s.trim()).filter(Boolean);
    if (segments.length < 2) return null;
    const filtered = segments.filter(s => !this.isNoiseText(s) && !this.isInvalidSingerName(s));
    if (filtered.length >= 2) return this.determineOrder(filtered[0], filtered[1]);
    return this.determineOrder(segments[0], segments[1]);
  }

  private determineOrder(a: string, b: string): SongInfo {
    const shortNamePattern = /^[\u4e00-\u9fff]{2,4}$/;
    const englishNamePattern = /^[A-Za-z]+(\s[A-Za-z]+)?$/;
    const aIsShort = shortNamePattern.test(a) || englishNamePattern.test(a);
    const bIsShort = shortNamePattern.test(b) || englishNamePattern.test(b);

    if (aIsShort && !bIsShort) return { singer: a, title: b };
    if (bIsShort && !aIsShort) return { singer: b, title: a };
    if (a.length > 6 && b.length <= 4) return { singer: b, title: a };
    if (b.length > 6 && a.length <= 4) return { singer: a, title: b };
    if (/[、&]/.test(a) && !/[、&]/.test(b)) return { singer: a, title: b };
    if (/[、&]/.test(b) && !/[、&]/.test(a)) return { singer: b, title: a };
    const aHasChinese = /[\u4e00-\u9fff]/.test(a);
    const bHasChinese = /[\u4e00-\u9fff]/.test(b);
    if (!aHasChinese && bHasChinese) return { singer: a, title: b };
    if (!bHasChinese && aHasChinese) return { singer: b, title: a };
    return { singer: b, title: a };
  }

  private isInvalidSingerName(name: string): boolean {
    if (!name || name.length === 0) return true;
    // 纯数字（如“2021”）不可能是歌手
    if (/^\d+$/.test(name)) return true;
    const hasChinese = /[\u4e00-\u9fff]/.test(name);
    if (hasChinese) {
      if (/[，。！？；：、“”‘’…（）《》【】]/.test(name)) return true;
      if (/[!?,.]/.test(name)) return true;
      const spokenWords = /[的我你是他她它这那听看说要去会能]/g;
      const spokenCount = (name.match(spokenWords) || []).length;
      if (name.length <= 4 && spokenCount >= 2) return true;
      if (spokenCount >= 3) return true;
      if (name.length > 8) return true;
    }
    if (/\d+万|评论/.test(name)) return true;
    return false;
  }

  private isNoiseText(text: string): boolean {
    return this.noiseKeywords.some(kw => text.toLowerCase().includes(kw.toLowerCase()));
  }

  private isChannelName(name: string): boolean {
    const channelPatterns: RegExp[] = [
      /音乐$/i, /Music$/i, /FM$/i, /Channel$/i, /^MV$/i, /^Official$/i, /^[A-Z]{2,10}$/
    ];
    if (channelPatterns.some(p => p.test(name.trim()))) return true;
    return name.length > 15 && /[\s\-_|]/.test(name);
  }

  private introMentionsName(intro: string, name: string): boolean {
    if (!intro || intro === '-') return false;
    const m = intro.match(/(?:演唱|歌手|主唱)\s*[:：]\s*([^\n\/\,，；;（(]+)/);
    return m !== null && m[1].includes(name);
  }

  private validate(
    result: SongInfo,
    intro: string,
    baseConfidence: number
  ): SongInfo {
    const singer = result.singer;
    if (this.isChannelName(singer) && !this.introMentionsName(intro, singer)) {
      return { singer: '', title: result.title, confidence: baseConfidence - 0.3 };
    }
    if (singer && this.isInvalidSingerName(singer)) {
      return { singer: '', title: result.title, confidence: baseConfidence - 0.2 };
    }
    return { singer: result.singer, title: result.title, confidence: baseConfidence };
  }
}
