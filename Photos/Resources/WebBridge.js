/* Generated from webbridge/ + third_party/gptk by tools/build-webbridge.sh. Do not edit.
 * Contains code from Google Photos Toolkit, Copyright (c) 2024 xob0t,
 * MIT License: https://github.com/xob0t/Google-Photos-Toolkit/blob/main/LICENSE
 * Bridge sources Copyright (C) 2026 Jaroslav Sazma, GPL-3.0-or-later. */
"use strict";
(() => {
  // ../third_party/gptk/src/api/parser.ts
  function libraryItemParse(itemData) {
    return {
      mediaKey: itemData?.[0],
      timestamp: itemData?.[2],
      timezoneOffset: itemData?.[4],
      creationTimestamp: itemData?.[5],
      dedupKey: itemData?.[3],
      thumb: itemData?.[1]?.[0],
      resWidth: itemData?.[1]?.[1],
      resHeight: itemData?.[1]?.[2],
      isPartialUpload: itemData[12]?.[0] === 20,
      isArchived: itemData?.[13],
      isFavorite: itemData?.at(-1)?.[163238866]?.[0],
      duration: itemData?.at(-1)?.[76647426]?.[0],
      descriptionShort: itemData?.at(-1)?.[396644657]?.[0],
      isLivePhoto: itemData?.at(-1)?.[146008172] ? true : false,
      livePhotoDuration: itemData?.at(-1)?.[146008172]?.[1],
      isOwned: itemData[7]?.filter((subArray) => subArray.includes(27)).length === 0,
      geoLocation: {
        coordinates: itemData?.at(-1)?.[129168200]?.[1]?.[0],
        name: itemData?.at(-1)?.[129168200]?.[1]?.[4]?.[0]?.[1]?.[0]?.[0]
      }
    };
  }
  function libraryTimelinePage(data) {
    return {
      items: data?.[0]?.map((itemData) => libraryItemParse(itemData)),
      nextPageId: data?.[1],
      lastItemTimestamp: parseInt(data?.[2])
    };
  }
  function libraryGenericPage(data) {
    return {
      items: data?.[0]?.map((itemData) => libraryItemParse(itemData)),
      nextPageId: data?.[1]
    };
  }
  function lockedFolderItemParse(itemData) {
    return {
      mediaKey: itemData?.[0],
      timestamp: itemData?.[2],
      creationTimestamp: itemData?.[5],
      dedupKey: itemData?.[3],
      duration: itemData?.at(-1)?.[76647426]?.[0]
    };
  }
  function lockedFolderPage(data) {
    return {
      nextPageId: data?.[0],
      items: data?.[1]?.map((itemData) => lockedFolderItemParse(itemData))
    };
  }
  function linkParse(itemData) {
    return {
      mediaKey: itemData?.[6],
      linkId: itemData?.[17],
      itemCount: itemData?.[3]
    };
  }
  function linksPage(data) {
    return {
      items: data?.[0]?.map((itemData) => linkParse(itemData)),
      nextPageId: data?.[1]
    };
  }
  function albumParse(itemData) {
    return {
      mediaKey: itemData?.[0],
      ownerActorId: itemData?.[6]?.[0],
      title: itemData?.at(-1)?.[72930366]?.[1],
      thumb: itemData?.[1]?.[0],
      itemCount: itemData?.at(-1)?.[72930366]?.[3],
      creationTimestamp: itemData?.at(-1)?.[72930366]?.[2]?.[4],
      modifiedTimestamp: itemData?.at(-1)?.[72930366]?.[2]?.[9],
      timestampRange: [itemData?.at(-1)?.[72930366]?.[2]?.[5], itemData?.at(-1)?.[72930366]?.[2]?.[6]],
      isShared: itemData?.at(-1)?.[72930366]?.[4] ?? false,
      authKey: itemData?.at(-1)?.[72930366]?.[5] ?? void 0
    };
  }
  function albumsPage(data) {
    return {
      items: data?.[0]?.map((itemData) => albumParse(itemData)),
      nextPageId: data?.[1]
    };
  }
  function partnerSharedItemParse(itemData) {
    return {
      mediaKey: itemData?.[0],
      thumb: itemData?.[1]?.[0],
      resWidth: itemData[1]?.[1],
      resHeight: itemData[1]?.[2],
      timestamp: itemData?.[2],
      timezoneOffset: itemData?.[4],
      creationTimestamp: itemData?.[5],
      dedupKey: itemData?.[3],
      saved: itemData?.[7]?.[3]?.[0] !== 20,
      isLivePhoto: itemData?.at(-1)?.[146008172] ? true : false,
      livePhotoDuration: itemData?.at(-1)?.[146008172]?.[1],
      duration: itemData?.at(-1)?.[76647426]?.[0]
    };
  }
  function albumItemParse(itemData) {
    return {
      mediaKey: itemData?.[0],
      thumb: itemData?.[1]?.[0],
      resWidth: itemData[1]?.[1],
      resHeight: itemData[1]?.[2],
      timestamp: itemData?.[2],
      timezoneOffset: itemData?.[4],
      creationTimestamp: itemData?.[5],
      dedupKey: itemData?.[3],
      isLivePhoto: itemData?.at(-1)?.[146008172] ? true : false,
      livePhotoDuration: itemData?.at(-1)?.[146008172]?.[1],
      duration: itemData?.at(-1)?.[76647426]?.[0]
    };
  }
  function trashItemParse(itemData) {
    return {
      mediaKey: itemData?.[0],
      thumb: itemData?.[1]?.[0],
      resWidth: itemData?.[1]?.[1],
      resHeight: itemData?.[1]?.[2],
      timestamp: itemData?.[2],
      timezoneOffset: itemData?.[4],
      creationTimestamp: itemData?.[5],
      dedupKey: itemData?.[3],
      duration: itemData?.at(-1)?.[76647426]?.[0]
    };
  }
  function actorParse(data) {
    return {
      actorId: data?.[0],
      gaiaId: data?.[1],
      name: data?.[11]?.[0],
      gender: data?.[11]?.[2],
      profilePhotoUrl: data?.[12]?.[0]
    };
  }
  function partnerSharedItemsPage(data) {
    return {
      nextPageId: data?.[0],
      items: data?.[1]?.map((itemData) => partnerSharedItemParse(itemData)),
      members: data?.[2]?.map((itemData) => actorParse(itemData)),
      partnerActorId: data?.[4],
      gaiaId: data?.[5]
    };
  }
  function albumItemsPage(data) {
    return {
      items: data?.[1]?.map((itemData) => albumItemParse(itemData)),
      nextPageId: data?.[2],
      mediaKey: data?.[3]?.[0],
      title: data?.[3]?.[1],
      owner: actorParse(data?.[3]?.[5]),
      startTimestamp: data?.[3]?.[2]?.[5],
      endTimestamp: data?.[3]?.[2]?.[6],
      lastActivityTimestamp: data?.[3]?.[2]?.[7],
      creationTimestamp: data?.[3]?.[2]?.[8],
      newestOperationTimestamp: data?.[3]?.[2]?.[9],
      itemCount: data?.[3]?.[21],
      authKey: data?.[3]?.[19],
      members: data?.[3]?.[9]?.map((itemData) => actorParse(itemData))
    };
  }
  function trashPage(data) {
    return {
      items: data?.[0]?.map((itemData) => trashItemParse(itemData)),
      nextPageId: data?.[1]
    };
  }
  function itemBulkMediaInfoParse(itemData) {
    return {
      mediaKey: itemData?.[0],
      descriptionFull: itemData?.[1]?.[2],
      fileName: itemData?.[1]?.[3],
      timestamp: itemData?.[1]?.[6],
      timezoneOffset: itemData?.[1]?.[7],
      creationTimestamp: itemData?.[1]?.[8],
      size: itemData?.[1]?.[9],
      takesUpSpace: itemData?.[1]?.at(-1)?.[0] === void 0 ? null : itemData?.[1]?.at(-1)?.[0] === 1,
      spaceTaken: itemData?.[1]?.at(-1)?.[1],
      isOriginalQuality: itemData?.[1]?.at(-1)?.[2] === void 0 ? null : itemData?.[1]?.at(-1)?.[2] === 2
    };
  }
  function itemInfoExtParse(itemData) {
    const source = [null, null];
    const sourceMap = {
      1: "mobile",
      2: "web",
      3: "shared",
      4: "partnerShared",
      7: "drive",
      8: "pc",
      11: "gmail"
    };
    source[0] = itemData[0]?.[27]?.[0] ? sourceMap[itemData[0][27][0]] ?? null : null;
    const sourceMapSecondary = {
      1: "android",
      3: "ios"
    };
    source[1] = itemData[0]?.[27]?.[1]?.[2] ? sourceMapSecondary[itemData[0][27][1][2]] ?? null : null;
    let owner = null;
    if (itemData[0]?.[27]?.length > 0) {
      owner = actorParse(itemData[0]?.[27]?.[3]?.[0] ?? itemData[0]?.[27]?.[4]?.[0]);
    }
    if (!owner?.actorId) {
      owner = actorParse(itemData[0]?.[28]);
    }
    return {
      mediaKey: itemData[0]?.[0],
      dedupKey: itemData[0]?.[11],
      descriptionFull: itemData[0]?.[1],
      fileName: itemData[0]?.[2],
      timestamp: itemData[0]?.[3],
      timezoneOffset: itemData[0]?.[4],
      size: itemData[0]?.[5],
      resWidth: itemData[0]?.[6],
      resHeight: itemData[0]?.[7],
      cameraInfo: itemData[0]?.[23],
      albums: itemData[0]?.[19]?.map((album) => albumParse(album)),
      source,
      takesUpSpace: itemData[0]?.[30]?.[0] === void 0 ? null : itemData[0]?.[30]?.[0] === 1,
      spaceTaken: itemData[0]?.[30]?.[1],
      isOriginalQuality: itemData[0]?.[30]?.[2] === void 0 ? null : itemData[0][30][2] === 2,
      savedToYourPhotos: itemData[0]?.[12].filter((subArray) => subArray.includes(20)).length === 0,
      owner,
      geoLocation: {
        coordinates: itemData[0]?.[9]?.[0] ?? itemData[0]?.[13]?.[0],
        name: itemData[0]?.[13]?.[2]?.[0]?.[1]?.[0]?.[0],
        mapThumb: itemData?.[1]
      },
      other: itemData[0]?.[31]
    };
  }
  function itemInfoParse(itemData) {
    const knownKeys = ["15", "76647426", "146008172", "163238866", "225032867", "318563170", "525000000"];
    const extObj = itemData[0]?.find(
      (x) => x && typeof x === "object" && !Array.isArray(x) && Object.keys(x).some((k) => knownKeys.includes(k))
    );
    return {
      mediaKey: itemData[0]?.[0],
      dedupKey: itemData[0]?.[3],
      resWidth: itemData[0]?.[1]?.[1],
      resHeight: itemData[0]?.[1]?.[2],
      isPartialUpload: itemData[0]?.[12]?.[0] === 20,
      timestamp: itemData[0]?.[2],
      timezoneOffset: itemData[0]?.[4],
      creationTimestamp: itemData[0]?.[5],
      downloadUrl: itemData?.[1],
      downloadOriginalUrl: itemData?.[7],
      savedToYourPhotos: extObj?.[163238866]?.length > 0,
      isArchived: itemData[0]?.[13],
      takesUpSpace: extObj?.[318563170]?.[0]?.[0] === void 0 ? null : extObj?.[318563170]?.[0]?.[0] === 1,
      spaceTaken: extObj?.[318563170]?.[0]?.[1],
      isOriginalQuality: extObj?.[318563170]?.[0]?.[2] === void 0 ? null : extObj?.[318563170]?.[0]?.[2] === 2,
      isFavorite: extObj?.[163238866]?.[0],
      duration: extObj?.[76647426]?.[0],
      isLivePhoto: extObj?.[146008172] ? true : false,
      livePhotoDuration: extObj?.[146008172]?.[1],
      livePhotoVideoDownloadUrl: extObj?.[146008172]?.[3],
      trashTimestamp: extObj?.[225032867]?.[0],
      descriptionFull: itemData[10],
      thumb: itemData[12],
      cameraInfo: itemData[0]?.[1]?.[8]?.[4]
    };
  }
  function bulkMediaInfo(data) {
    return data.map((itemData) => itemBulkMediaInfoParse(itemData));
  }
  function downloadTokenCheckParse(data) {
    return {
      fileName: data?.[0]?.[0]?.[0]?.[2]?.[0]?.[0],
      downloadUrl: data?.[0]?.[0]?.[0]?.[2]?.[0]?.[1],
      downloadSize: data?.[0]?.[0]?.[0]?.[2]?.[0]?.[2],
      unzippedSize: data?.[0]?.[0]?.[0]?.[2]?.[0]?.[3]
    };
  }
  function storageQuotaParse(data) {
    return {
      totalUsed: data?.[6]?.[0],
      totalAvailable: data?.[6]?.[1],
      usedByGPhotos: data?.[6]?.[3]
    };
  }
  function remoteMatchParse(itemData) {
    return {
      hash: itemData?.[0],
      mediaKey: itemData?.[1]?.[0],
      thumb: itemData?.[1]?.[1]?.[0],
      resWidth: itemData?.[1]?.[1]?.[1],
      resHeight: itemData?.[1]?.[1]?.[2],
      timestamp: itemData?.[1]?.[2],
      dedupKey: itemData?.[1]?.[3],
      timezoneOffset: itemData?.[1]?.[4],
      creationTimestamp: itemData?.[1]?.[5],
      duration: itemData?.[1]?.at(-1)?.[76647426]?.[0],
      cameraInfo: itemData?.[1]?.[1]?.[8]
    };
  }
  function remoteMatchesParse(data) {
    return data?.[0]?.map((itemData) => remoteMatchParse(itemData)) ?? [];
  }
  var parserRegistry = {
    "lcxiM": libraryTimelinePage,
    "nMFwOc": lockedFolderPage,
    "EzkLib": libraryGenericPage,
    "F2A0H": linksPage,
    "Z5xsfc": albumsPage,
    "snAcKc": albumItemsPage,
    "e9T5je": partnerSharedItemsPage,
    "zy0IHe": trashPage,
    "VrseUb": itemInfoParse,
    "fDcn4b": itemInfoExtParse,
    "EWgK9e": bulkMediaInfo,
    "dnv2s": downloadTokenCheckParse,
    "EzwWhf": storageQuotaParse,
    "swbisb": remoteMatchesParse
  };
  function parser(data, rpcid) {
    if (!data?.length) return null;
    const parserFn = parserRegistry[rpcid];
    if (parserFn) return parserFn(data);
    return null;
  }

  // ../third_party/gptk/src/windowGlobalData.ts
  var windowGlobalData = {
    rapt: window.WIZ_global_data.Dbw5Ud,
    account: window.WIZ_global_data.oPEP7c,
    "f.sid": window.WIZ_global_data.FdrFJe,
    bl: window.WIZ_global_data.cfb2h,
    path: window.WIZ_global_data.eptZe,
    at: window.WIZ_global_data.SNlM0e
  };

  // ../third_party/gptk/src/api/api.ts
  var Api = class _Api {
    static {
      this.MAX_RETRIES = 3;
    }
    static {
      this.RETRY_BASE_DELAY_MS = 2e3;
    }
    /**
     * Core RPC request with retry and response validation.
     *
     * Fixes #74, #85, #96, #110 — the Google batchexecute endpoint can
     * return empty bodies, HTTP errors, or responses without the expected
     * `wrb.fr` envelope (e.g. rate-limiting, timeouts).  Previously this
     * caused `JSON.parse(undefined)` to throw an opaque SyntaxError.
     * We now validate every step and retry with exponential backoff.
     *
     * @param rpcid - The RPC method identifier (e.g. `'lcxiM'`, `'EzkLib'`).
     * @param requestData - The payload to send, will be JSON-stringified.
     * @returns The parsed JSON payload from the `wrb.fr` envelope.
     */
    async makeApiRequest(rpcid, requestData) {
      const wrappedData = [[[rpcid, JSON.stringify(requestData), null, "generic"]]];
      const requestDataString = `f.req=${encodeURIComponent(JSON.stringify(wrappedData))}&at=${encodeURIComponent(windowGlobalData.at)}&`;
      const params = {
        rpcids: rpcid,
        "source-path": window.location.pathname,
        "f.sid": windowGlobalData["f.sid"],
        bl: windowGlobalData.bl,
        pageId: "none",
        rt: "c"
      };
      if (typeof windowGlobalData.rapt === "string") params["rapt"] = windowGlobalData.rapt;
      const paramsString = Object.keys(params).map((key) => `${key}=${encodeURIComponent(params[key])}`).join("&");
      const url = `https://photos.google.com${windowGlobalData.path}data/batchexecute?${paramsString}`;
      let lastError = null;
      for (let attempt = 1; attempt <= _Api.MAX_RETRIES; attempt++) {
        try {
          const response = await fetch(url, {
            headers: {
              "content-type": "application/x-www-form-urlencoded;charset=UTF-8"
            },
            body: requestDataString,
            method: "POST",
            credentials: "include"
          });
          if (!response.ok) {
            throw new Error(`HTTP ${response.status} ${response.statusText}`);
          }
          const responseBody = await response.text();
          if (!responseBody) {
            throw new Error("Empty response body");
          }
          const jsonLines = responseBody.split("\n").filter((line) => line.includes("wrb.fr"));
          if (jsonLines.length === 0) {
            throw new Error("No wrb.fr envelope found in response");
          }
          const parsedData = JSON.parse(jsonLines[0]);
          if (!parsedData?.[0]?.[2]) {
            throw new Error("Missing payload in parsed response");
          }
          return JSON.parse(parsedData[0][2]);
        } catch (error) {
          lastError = error instanceof Error ? error : new Error(String(error));
          console.error(`Error in ${rpcid} request (attempt ${attempt}/${_Api.MAX_RETRIES}):`, lastError.message);
          if (attempt < _Api.MAX_RETRIES) {
            const delay = _Api.RETRY_BASE_DELAY_MS * attempt;
            await new Promise((resolve) => setTimeout(resolve, delay));
          }
        }
      }
      throw lastError ?? new Error(`${rpcid} request failed after ${_Api.MAX_RETRIES} attempts`);
    }
    async getItemsByTakenDate(timestamp = null, source = null, pageId = null, pageSize = 500, parseResponse = true) {
      let sourceCode;
      if (source === "library") sourceCode = 1;
      else if (source === "archive") sourceCode = 2;
      else sourceCode = 3;
      const rpcid = "lcxiM";
      const requestData = [pageId, timestamp, pageSize, null, 1, sourceCode];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getItemsByTakenDate:", error);
        throw error;
      }
    }
    async getItemsByUploadedDate(pageId = null, parseResponse = true) {
      const rpcid = "EzkLib";
      const requestData = ["", [[4, "ra", 0, 0]], pageId];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getItemsByUploadedDate:", error);
        throw error;
      }
    }
    async search(searchQuery, pageId = null, parseResponse = true) {
      const rpcid = "EzkLib";
      const requestData = [searchQuery, null, pageId];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in search:", error);
        throw error;
      }
    }
    async getRemoteMatchesByHash(hashArray, parseResponse = true) {
      const rpcid = "swbisb";
      const requestData = [hashArray, null, 3, 0];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getRemoteMatchesByHash:", error);
        throw error;
      }
    }
    async getFavoriteItems(pageId = null, parseResponse = true) {
      const rpcid = "EzkLib";
      const requestData = ["Favorites", [[5, "8", 0, 9]], pageId];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getFavoriteItems:", error);
        throw error;
      }
    }
    async getTrashItems(pageId = null, parseResponse = true) {
      const rpcid = "zy0IHe";
      const requestData = [pageId];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getTrashItems:", error);
        throw error;
      }
    }
    async getLockedFolderItems(pageId = null, parseResponse = true) {
      const rpcid = "nMFwOc";
      const requestData = [pageId];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getLockedFolderItems:", error);
        throw error;
      }
    }
    async moveItemsToTrash(dedupKeyArray) {
      const rpcid = "XwAOJf";
      const requestData = [null, 1, dedupKeyArray, 3];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response[0];
      } catch (error) {
        console.error("Error in moveItemsToTrash:", error);
        throw error;
      }
    }
    async restoreFromTrash(dedupKeyArray) {
      const rpcid = "XwAOJf";
      const requestData = [null, 3, dedupKeyArray, 2];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response[0];
      } catch (error) {
        console.error("Error in restoreFromTrash:", error);
        throw error;
      }
    }
    async getSharedLinks(pageId = null, parseResponse = true) {
      const rpcid = "F2A0H";
      const requestData = [pageId, null, 2, null, 3];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getSharedLinks:", error);
        throw error;
      }
    }
    async getAlbums(pageId = null, pageSize = 100, parseResponse = true) {
      const rpcid = "Z5xsfc";
      const requestData = [pageId, null, null, null, 1, null, null, pageSize, [2], 5];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getAlbums:", error);
        throw error;
      }
    }
    async getAlbumPage(albumMediaKey, pageId = null, authKey = null, parseResponse = true) {
      const rpcid = "snAcKc";
      const requestData = [albumMediaKey, pageId, null, authKey];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getAlbumPage:", error);
        throw error;
      }
    }
    async removeItemsFromAlbum(itemAlbumMediaKeyArray) {
      const rpcid = "ycV3Nd";
      const requestData = [itemAlbumMediaKeyArray];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in removeItemsFromAlbum:", error);
        throw error;
      }
    }
    async createAlbum(albumName) {
      const rpcid = "OXvT9d";
      const requestData = [albumName, null, 2];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response?.[0]?.[0];
      } catch (error) {
        console.error("Error in createAlbum:", error);
        throw error;
      }
    }
    async addItemsToAlbum(mediaKeyArray, albumMediaKey = null, albumName = null) {
      const rpcid = "E1Cajb";
      let requestData = null;
      if (albumName) requestData = [mediaKeyArray, null, albumName];
      else if (albumMediaKey) requestData = [mediaKeyArray, albumMediaKey];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in addItemsToAlbum:", error);
        throw error;
      }
    }
    async addItemsToSharedAlbum(mediaKeyArray, albumMediaKey = null, albumName = null) {
      const rpcid = "laUYf";
      let requestData = null;
      if (albumName) requestData = [mediaKeyArray, null, albumName];
      else if (albumMediaKey) requestData = [albumMediaKey, [2, null, mediaKeyArray.map((id) => [[id]]), null, null, null, [1]]];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in addItemsToSharedAlbum:", error);
        throw error;
      }
    }
    async setAlbumItemOrder(albumMediaKey, albumItemKeys, insertAfter = null) {
      const rpcid = "QD9nKf";
      const albumItemKeysArray = albumItemKeys.map((item) => [[item]]);
      let requestData;
      if (insertAfter) {
        requestData = [albumMediaKey, null, 3, null, albumItemKeysArray, [[insertAfter]]];
      } else {
        requestData = [albumMediaKey, null, 1, null, albumItemKeysArray];
      }
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in setAlbumItemOrder:", error);
        throw error;
      }
    }
    async setFavorite(dedupKeyArray, action = true) {
      const actionCode = action ? 1 : 2;
      const mappedKeys = dedupKeyArray.map((item) => [null, item]);
      const rpcid = "Ftfh0";
      const requestData = [mappedKeys, [actionCode]];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in setFavorite:", error);
        throw error;
      }
    }
    async setArchive(dedupKeyArray, action = true) {
      const actionCode = action ? 1 : 2;
      const mappedKeys = dedupKeyArray.map((item) => [null, [actionCode], [null, item]]);
      const rpcid = "w7TP3c";
      const requestData = [mappedKeys, null, 1];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in setArchive:", error);
        throw error;
      }
    }
    async moveToLockedFolder(dedupKeyArray) {
      const rpcid = "StLnCe";
      const requestData = [dedupKeyArray, []];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in moveToLockedFolder:", error);
        throw error;
      }
    }
    async removeFromLockedFolder(dedupKeyArray) {
      const rpcid = "Pp2Xxe";
      const requestData = [dedupKeyArray];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in removeFromLockedFolder:", error);
        throw error;
      }
    }
    async getStorageQuota(parseResponse = true) {
      const rpcid = "EzwWhf";
      const requestData = [];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getStorageQuota:", error);
        throw error;
      }
    }
    async getDownloadUrl(mediaKeyArray, authKey = null) {
      const rpcid = "pLFTfd";
      const requestData = [mediaKeyArray, null, authKey];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response[0];
      } catch (error) {
        console.error("Error in getDownloadUrl:", error);
        throw error;
      }
    }
    async getDownloadToken(mediaKeyArray) {
      const rpcid = "yCLA7";
      const mappedKeys = mediaKeyArray.map((id) => [id]);
      const requestData = [mappedKeys];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response[0];
      } catch (error) {
        console.error("Error in getDownloadToken:", error);
        throw error;
      }
    }
    async checkDownloadToken(dlToken, parseResponse = true) {
      const rpcid = "dnv2s";
      const requestData = [[dlToken]];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in checkDownloadToken:", error);
        throw error;
      }
    }
    async removeItemsFromSharedAlbum(albumMediaKey, mediaKeyArray) {
      const rpcid = "LjmOue";
      const requestData = [
        [albumMediaKey],
        [mediaKeyArray],
        [[null, null, null, [null, [], []], null, null, null, null, null, null, null, null, null, []]]
      ];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in removeItemsFromSharedAlbum:", error);
        throw error;
      }
    }
    async saveSharedMediaToLibrary(albumMediaKey, mediaKeyArray) {
      const rpcid = "V8RKJ";
      const requestData = [mediaKeyArray, null, albumMediaKey];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in saveSharedMediaToLibrary:", error);
        throw error;
      }
    }
    async savePartnerSharedMediaToLibrary(mediaKeyArray) {
      const rpcid = "Es7fke";
      const mappedKeys = mediaKeyArray.map((id) => [id]);
      const requestData = [mappedKeys];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in savePartnerSharedMediaToLibrary:", error);
        throw error;
      }
    }
    async getPartnerSharedMedia(partnerActorId, gaiaId, pageId, parseResponse = true) {
      const rpcid = "e9T5je";
      const requestData = [pageId, null, [null, [[[2, 1]]], [partnerActorId], [null, gaiaId], 1]];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getPartnerSharedMedia:", error);
        throw error;
      }
    }
    async setItemGeoData(dedupKeyArray, center, visible1, visible2, scale, gMapsPlaceId) {
      const rpcid = "EtUHOe";
      const mappedKeys = dedupKeyArray.map((dedupKey) => [null, dedupKey]);
      const requestData = [mappedKeys, [2, center, [visible1, visible2], [null, null, scale], gMapsPlaceId]];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in setItemGeoData:", error);
        throw error;
      }
    }
    async deleteItemGeoData(dedupKeyArray) {
      const rpcid = "EtUHOe";
      const mappedKeys = dedupKeyArray.map((dedupKey) => [null, dedupKey]);
      const requestData = [mappedKeys, [1]];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in deleteItemGeoData:", error);
        throw error;
      }
    }
    async setItemsTimestamp(items) {
      const rpcid = "DaSgWe";
      const requestData = [items.map((item) => [item.dedupKey, item.timestampSec, item.timezoneSec])];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in setItemsTimestamp:", error);
        throw error;
      }
    }
    async setItemDescription(dedupKey, description) {
      const rpcid = "AQNOFd";
      const requestData = [null, description, dedupKey];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        return response;
      } catch (error) {
        console.error("Error in setItemDescription:", error);
        throw error;
      }
    }
    async getItemInfo(mediaKey, albumMediaKey = null, authKey = null, parseResponse = true) {
      const rpcid = "VrseUb";
      const requestData = [mediaKey, null, authKey, null, albumMediaKey];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getItemInfo:", error);
        throw error;
      }
    }
    // Only works with mediaKey belonging to your library
    async getItemInfoExt(mediaKey, authKey = null, parseResponse = true) {
      const rpcid = "fDcn4b";
      const requestData = [mediaKey, 1, authKey, null, 1];
      try {
        const response = await this.makeApiRequest(rpcid, requestData);
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getItemInfoExt:", error);
        throw error;
      }
    }
    async getBatchMediaInfo(mediaKeyArray, parseResponse = true) {
      const rpcid = "EWgK9e";
      const mappedKeys = mediaKeyArray.map((id) => [id]);
      const requestData = [[[mappedKeys], [[null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, [], null, null, null, null, null, null, null, null, null, null, []]]]];
      try {
        let response = await this.makeApiRequest(rpcid, requestData);
        response = response?.[0]?.[1];
        if (parseResponse) return parser(response, rpcid);
        return response;
      } catch (error) {
        console.error("Error in getBatchMediaInfo:", error);
        throw error;
      }
    }
  };

  // src/bridge.ts
  var api = new Api();
  var RENAME_ALBUM_RPCID = "SVP9Xd";
  var RENAME_SHARED_ALBUM_RPCID = "uF3Orb";
  var SHARE_ALBUM_RPCID = "SFKp8c";
  function diag() {
    const w = window;
    const g = w.WIZ_global_data ?? {};
    return {
      href: w.location?.href ?? null,
      pathname: w.location?.pathname ?? null,
      hasWiz: typeof w.WIZ_global_data !== "undefined",
      atLength: typeof g.SNlM0e === "string" ? g.SNlM0e.length : null,
      hasFsid: typeof g.FdrFJe === "string",
      hasBl: typeof g.cfb2h === "string",
      path: typeof g.eptZe === "string" ? g.eptZe : null
    };
  }
  async function singleShotApiRequest(rpcid, requestData, contextSourcePath) {
    const w = window;
    const g = w.WIZ_global_data ?? {};
    const str = (key) => typeof g[key] === "string" ? g[key] : "";
    const params = new URLSearchParams({
      rpcids: rpcid,
      "source-path": contextSourcePath ?? window.location?.pathname ?? "/",
      "f.sid": str("FdrFJe"),
      bl: str("cfb2h")
    });
    if (contextSourcePath) {
      params.set("hl", w.document?.documentElement?.lang || "en");
      params.set("soc-app", "165");
      params.set("soc-platform", "1");
      params.set("soc-device", "1");
      params.set("_reqid", String(Math.floor(1e5 + Math.random() * 9e5)));
    } else {
      params.set("pageId", "none");
    }
    params.set("rt", "c");
    const wrapped = [[[rpcid, JSON.stringify(requestData), null, "generic"]]];
    const body = `f.req=${encodeURIComponent(JSON.stringify(wrapped))}&at=${encodeURIComponent(str("SNlM0e"))}&`;
    const path = str("eptZe") || "/_/PhotosUi/";
    const headers = { "content-type": "application/x-www-form-urlencoded;charset=UTF-8" };
    if (contextSourcePath) headers["x-same-domain"] = "1";
    const response = await fetch(`https://photos.google.com${path}data/batchexecute?${params.toString()}`, {
      method: "POST",
      headers,
      body,
      credentials: "include",
      // the page context travels in the Referer too, not just in source-path
      ...contextSourcePath ? { referrer: `https://photos.google.com${contextSourcePath}` } : {}
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`HTTP ${response.status}; body: ${text.slice(0, 300)}`);
    const line = text.split("\n").find((l) => l.includes("wrb.fr"));
    if (!line) throw new Error(`No wrb.fr envelope in response: ${text.slice(0, 300)}`);
    const parsed = JSON.parse(line);
    if (!parsed?.[0]?.[2]) throw new Error(`${rpcid} returned no payload; envelope: ${line.slice(0, 300)}`);
  }
  var bridge = {
    ping() {
      return { ok: true };
    },
    diag,
    async getAlbumsPage(pageId) {
      return api.getAlbums(pageId);
    },
    async getLibraryPage(fromTimestamp, pageId) {
      return api.getItemsByTakenDate(fromTimestamp, null, pageId);
    },
    async getAlbumItemsPage(albumMediaKey, pageId, authKey) {
      return api.getAlbumPage(albumMediaKey, pageId, authKey);
    },
    async createAlbum(name) {
      return api.createAlbum(name);
    },
    async addItemsToAlbum(mediaKeys, albumMediaKey) {
      await api.addItemsToAlbum(mediaKeys, albumMediaKey);
    },
    async addItemsToSharedAlbum(mediaKeys, albumMediaKey) {
      await api.addItemsToSharedAlbum(mediaKeys, albumMediaKey);
    },
    async getTrashPage(pageId) {
      return api.getTrashItems(pageId);
    },
    async moveItemsToTrash(dedupKeys) {
      await api.moveItemsToTrash(dedupKeys);
    },
    async restoreFromTrash(dedupKeys) {
      await api.restoreFromTrash(dedupKeys);
    },
    async getBatchMediaInfo(mediaKeys) {
      return api.getBatchMediaInfo(mediaKeys);
    },
    // both take the album-scoped item mediaKeys an album page returns, not dedupKeys
    async removeItemsFromAlbum(itemMediaKeys) {
      await api.removeItemsFromAlbum(itemMediaKeys);
    },
    async removeItemsFromSharedAlbum(albumMediaKey, itemMediaKeys) {
      await singleShotApiRequest("LjmOue", [
        [albumMediaKey],
        itemMediaKeys.map((key) => [key]),
        [[null, null, null, [null, [], []], null, null, null, null, null, null, null, null, null, []]]
      ], `/share/${albumMediaKey}`);
    },
    async renameAlbum(albumMediaKey, newTitle, isShared) {
      const rpcid = isShared ? RENAME_SHARED_ALBUM_RPCID : RENAME_ALBUM_RPCID;
      const payload = isShared ? [[albumMediaKey], newTitle] : [albumMediaKey, newTitle];
      try {
        await api.makeApiRequest(rpcid, payload);
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        if (!message.includes("Missing payload in parsed response")) throw e;
      }
    },
    async shareAlbum(albumMediaKey, emails) {
      const options = [null, 1, null, null, 1, null, [[[1, 1], 1], [[1, 2], 1], [[2, 1], 1], [[2, 2], 1], [[3, 1], 0]], null, null, null, null, null, null, [1, 2]];
      const recipients = emails.map((email) => [5, email, [email], 2]);
      await singleShotApiRequest(SHARE_ALBUM_RPCID, [
        null,
        null,
        options,
        [1, [[albumMediaKey], [1, 2, 3]], null, null, null, null, [1]],
        null,
        [null, recipients],
        null,
        null,
        [1, 2, 3, 5, 6]
      ], `/album/${albumMediaKey}`);
    }
  };
  async function callJSON(method, argsJSON) {
    try {
      const args = JSON.parse(argsJSON);
      const fn = bridge[method];
      if (typeof fn !== "function") throw new Error(`Unknown bridge method: ${String(method)}`);
      const result = await fn.apply(bridge, args);
      return JSON.stringify({ ok: true, value: result ?? null });
    } catch (e) {
      const err = e instanceof Error ? e : new Error(String(e));
      return JSON.stringify({ ok: false, error: err.message, stack: err.stack ?? null, diag: diag() });
    }
  }
  window.cuePhotos = Object.assign({}, bridge, { callJSON });
})();
;0;
