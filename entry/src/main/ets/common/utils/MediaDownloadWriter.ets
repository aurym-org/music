/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';

/** Owns the HTTP stream and sequential asynchronous writes for one file. */
export class MediaDownloadWriter {
  private static readonly MAX_RESPONSE_BYTES: number = 100 * 1024 * 1024;
  private static readonly CONNECT_TIMEOUT_MS: number = 15000;
  private static readonly READ_TIMEOUT_MS: number = 60000;
  private static readonly MAX_REDIRECTS: number = 5;

  public static async download(
    url: string,
    headers: Record<string, string>,
    path: string,
    isCurrent: () => boolean
  ): Promise<void> {
    const request = http.createHttp();
    let file: fileIo.File;
    try {
      file = fileIo.openSync(
        path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
      );
    } catch (error) {
      request.destroy();
      throw new Error(error.message);
    }

    let receivedBytes = 0;
    let writeError: Error | undefined;
    let resolveDataEnd: () => void = () => {};
    const dataEnd = new Promise<void>((resolve) => {
      resolveDataEnd = resolve;
    });
    let writeQueue: Promise<void> = Promise.resolve();

    const onDataReceive = (chunk: ArrayBuffer): void => {
      if (chunk.byteLength === 0 || writeError || !isCurrent()) {
        return;
      }
      receivedBytes += chunk.byteLength;
      writeQueue = writeQueue.then(async () => {
        if (!writeError && isCurrent()) {
          await MediaDownloadWriter.writeChunk(file.fd, chunk);
        }
      }).catch((error: Error) => {
        writeError = error instanceof Error ? error : new Error(String(error));
        resolveDataEnd();
        request.destroy();
      });
    };
    const onDataEnd = (): void => {
      resolveDataEnd();
    };

    try {
      request.on('dataReceive', onDataReceive);
      request.on('dataEnd', onDataEnd);
      let responseCode: number;
      try {
        responseCode = await request.requestInStream(url, {
          method: http.RequestMethod.GET,
          header: headers,
          connectTimeout: MediaDownloadWriter.CONNECT_TIMEOUT_MS,
          readTimeout: MediaDownloadWriter.READ_TIMEOUT_MS,
          maxLimit: MediaDownloadWriter.MAX_RESPONSE_BYTES,
          maxRedirects: MediaDownloadWriter.MAX_REDIRECTS
        });
      } catch (error) {
        if (writeError) {
          throw writeError;
        }
        throw new Error(error.message);
      }
      if (responseCode !== 200) {
        throw new Error(`HTTP error: ${responseCode}`);
      }
      await dataEnd;
      await writeQueue;
      if (writeError) {
        throw writeError;
      }
      if (receivedBytes === 0) {
        throw new Error('Empty response body');
      }
    } finally {
      request.off('dataReceive', onDataReceive);
      request.off('dataEnd', onDataEnd);
      request.destroy();
      await writeQueue;
      fileIo.closeSync(file);
    }
  }

  private static async writeChunk(fd: number, chunk: ArrayBuffer): Promise<void> {
    let written = 0;
    while (written < chunk.byteLength) {
      const count = await fileIo.write(fd, chunk.slice(written));
      if (count <= 0) {
        throw new Error('Write file failed: no bytes written');
      }
      written += count;
    }
  }
}
