import { encode, decode, type Stored } from "./features/notes/noteCodec";
import { NoteMetadata } from "./features/notes/components/NoteMetadata";
(window as any).EXCALIDRAW_ASSET_PATH = new URL(
  "./",
  window.location.href,
).href;
import { ExcalidrawCanvas } from "./features/notes/components/ExcalidrawCanvas";
import { NoteCreateButtons } from "./features/notes/components/NoteCreateButtons";
import { SearchInput } from "./shared/components/SearchInput";
import { EmptyCard } from "./shared/components/EmptyCard";
import { NoteLinksPane } from "./features/notes/components/NoteLinksPane";
import { useState, useRef, useMemo, useEffect, useDeferredValue, useLayoutEffect } from "react";
import { createRoot } from "react-dom/client";
import {
  MarkdownPreview,
  type MarkdownPreviewHandle,
} from "./features/notes/components/MarkdownPreview";
import {
  MarkdownEditor,
  MarkdownEditorHandle,
} from "./features/notes/components/MarkdownEditor";
import { OutlinePane } from "./features/notes/components/OutlinePane";
import { NotePropertiesPanel } from "./features/notes/components/NotePropertiesPanel";
import { Icon } from "./shared/components/Icon";
import { Tooltip } from "./shared/components/Tooltip";
import { renderMarkdownDocument, extractMarkdownHeadings } from "./markdown";
import type { NoteDetail } from "./contracts";
type Card = {
  outgoingIDs?: string[];
  id: string;
  title: string;
  body: string;
  tags?: string[];
  type?: "markdown" | "excalidraw";
};
const post = (type: string, payload: object = {}) =>
  (window as any).webkit?.messageHandlers.notes.postMessage({
    type,
    ...payload,
  });
const requests = new Map<
  string,
  {
    resolve: (text: string | null) => void;
    reject: (error: Error) => void;
  }
>();
async function upload(file: File): Promise<string | null> {
  const data = await new Promise<string>((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).split(",")[1]);
    r.onerror = reject;
    r.readAsDataURL(file);
  });
  return new Promise((resolve, reject) => {
    const request = crypto.randomUUID();
    requests.set(request, { resolve, reject });
    post("attachments", {
      request,
      files: [{ name: file.name, type: file.type, data }],
    });
  });
}
let load: (data: Stored, notes: Card[], heading?: string) => void = () => {};
let updateCatalog: (notes: Card[]) => void = () => {};
let insert: (text: string) => void = () => {};
let setStatus: (text: string) => void = () => {};
let clear: () => void = () => {};
let deliverSearch: (request: string, ids: string[] | null) => void = () => {};
let current: NoteDetail | undefined;
function Reading({
  content,
  onOpen,
  preview,
}: {
  content: string;
  preview: React.RefObject<MarkdownPreviewHandle | null>;
  onOpen: (id: string, heading?: string) => void;
}) {
  const document = useMemo(() => renderMarkdownDocument(content), [content]);
  return (
    <div id="reading" className="h-full min-h-0">
      <MarkdownPreview
        ref={preview}
        document={document}
        className="h-full min-h-0 text-sm leading-6"
        onOpenNote={(id, heading) => onOpen(id, heading ?? undefined)}
      />
    </div>
  );
}
const VIRTUAL_NOTE_HEIGHT = 82;
const VIRTUAL_OVERSCAN = 6;
function VirtualNoteList({ items, currentID, onOpen }: { items: Card[]; currentID: string; onOpen: (id: string) => void }): React.JSX.Element {
  const [scrollTop, setScrollTop] = useState(0);
  const [viewportHeight, setViewportHeight] = useState(600);
  const viewportRef = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const viewport = viewportRef.current;
    if (!viewport) return;
    const update = () => setViewportHeight(viewport.clientHeight);
    update();
    const observer = new ResizeObserver(update);
    observer.observe(viewport);
    return () => observer.disconnect();
  }, []);
  const start = Math.max(0, Math.floor(scrollTop / VIRTUAL_NOTE_HEIGHT) - VIRTUAL_OVERSCAN);
  const end = Math.min(items.length, Math.ceil((scrollTop + viewportHeight) / VIRTUAL_NOTE_HEIGHT) + VIRTUAL_OVERSCAN);
  return <div ref={viewportRef} className="min-h-0 min-w-0 flex-1 overflow-y-auto overscroll-contain pr-2 -mr-2" onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}>
    <div style={{ height: items.length * VIRTUAL_NOTE_HEIGHT, position: 'relative' }}>
      <div style={{ position: 'absolute', top: start * VIRTUAL_NOTE_HEIGHT, left: 0, right: 0 }}>
        {items.slice(start, end).map((item, offset) => {
          const index = start + offset;
          return <div key={item.id} className="absolute left-0 right-0" style={{ top: index * VIRTUAL_NOTE_HEIGHT, height: 72 }}>
            <button type="button" data-selected={item.id === currentID || undefined} aria-current={item.id === currentID ? 'page' : undefined} className="station-list-item relative flex h-full w-full min-w-0 flex-col gap-1 text-left !pl-2" onClick={() => onOpen(item.id)}>
              <span className="station-item-bar" /><span className="flex min-w-0 items-center gap-2"><Icon name={item.type === 'excalidraw' ? 'excalidraw' : 'notes'} className="size-4 shrink-0 text-station-accent" /><span className="truncate text-sm">{item.title || '未命名笔记'}</span></span>
              <span className="line-clamp-2 text-xs leading-4 text-station-muted">{item.type === 'excalidraw' ? 'Excalidraw 画板' : item.body.slice(0, 160) || '暂无摘要'}</span>
            </button>
          </div>;
        })}
      </div>
    </div>
  </div>;
}
function App() {
  const [note, setNote] = useState<NoteDetail>();
  const [notes, setNotes] = useState<Card[]>([]);
  const [editing, setEditing] = useState(true);
  const [zen, setZen] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [canvasMounted, setCanvasMounted] = useState(false);
  useEffect(() => {
    if (note?.type === "excalidraw") setCanvasMounted(true);
  }, [note?.type]);
  const [sideTab, setSideTab] = useState("outline");
  const [tagDraft, setTagDraft] = useState("");
  const [query, setQuery] = useState<string | null>(null);
  const [status, statusSetter] = useState("");
  const [listQuery, setListQuery] = useState("");
  const [searchIDs, setSearchIDs] = useState<Set<string> | null>(null);
  const searchRequest = useRef("");
  deliverSearch = (request, ids) => {
    if (request === searchRequest.current)
      setSearchIDs(new Set((ids ?? []).map((id) => id.toLowerCase())));
  };
  useEffect(() => {
    searchRequest.current = crypto.randomUUID();
    if (!listQuery.trim()) {
      setSearchIDs(null);
      return;
    }
    const request = searchRequest.current;
    const timer = setTimeout(
      () => post("searchNotes", { request, query: listQuery }),
      150,
    );
    return () => clearTimeout(timer);
  }, [listQuery, notes]);
  const filteredNotes = useMemo(() => {
    const term = listQuery.trim().toLowerCase();
    return notes.filter(
      (item) =>
        !term ||
        searchIDs?.has(item.id.toLowerCase()) ||
        (item.id === note?.id &&
          `${item.title} ${item.type === "excalidraw" ? "" : item.body} ${(item.tags ?? []).join(" ")}`
            .toLowerCase()
            .includes(term)),
    );
  }, [listQuery, searchIDs, notes, note?.id]);
  const [heading, setHeading] = useState("");
  const ref = useRef<MarkdownEditorHandle>(null);
  const previewRef = useRef<MarkdownPreviewHandle>(null);
  useEffect(() => {
    if (editing) ref.current?.resume();
  }, [editing]);
  const deferred = useDeferredValue(note?.content ?? "");
  const wordCount = useMemo(
    () => deferred.match(/[\u4e00-\u9fff]|[\p{L}\p{N}_-]+/gu)?.length ?? 0,
    [deferred],
  );
  const headings = useMemo(
    () =>
      note?.type === "excalidraw" ? [] : extractMarkdownHeadings(deferred),
    [deferred, note?.type],
  );
  updateCatalog = (list) => setNotes(list);
  load = (data, list, anchor) => {
    previewRef.current?.scrollToLine(1);
    setNote(decode(data));
    setConfirmDelete(false);
    setNotes(
      list.some((item) => item.id === data.id)
        ? list
        : [
            {
              id: data.id,
              title: data.title,
              body: data.body,
              type: data.type,
            },
            ...list,
          ],
    );
    setHeading(anchor ?? "");
    setTagDraft("");
    setQuery(null);
    for (const request of requests.values()) request.resolve(null);
    requests.clear();
  };
  insert = (text) => ref.current?.insert(text);
  setStatus = (text) => {
    if (!/^(已保存|正在保存|正在加载)/.test(text)) statusSetter(text);
  };
  clear = () => {
    setNote(undefined);
    setNotes([]);
  };
  current = note;
  useEffect(() => {
    post("ready");
    const toast = (e: Event) => statusSetter((e as CustomEvent).detail);
    window.addEventListener("note-toast", toast);
    return () => window.removeEventListener("note-toast", toast);
  }, []);
  useEffect(() => {
    if (!note || !heading) return;
    let decoded = heading;
    try {
      decoded = decodeURIComponent(heading);
    } catch {}
    const target = headings.find(
      (h) =>
        h.text === decoded ||
        h.text.toLowerCase().replace(/\s+/g, "-") === decoded.toLowerCase(),
    );
    if (target) {
      const timer = setTimeout(() => {
        if (editing)
          document.querySelector(".cm-content")?.dispatchEvent(
            new CustomEvent("note-jump", {
              detail: note.content.slice(0, target.offset).split("\n").length,
            }),
          );
        else
          document
            .querySelector(`[data-heading-offset="${target.offset}"]`)
            ?.scrollIntoView({ block: "center" });
        setHeading("");
      }, 100);
      return () => clearTimeout(timer);
    }
  }, [note?.id, heading, headings, editing]);
  function change(patch: Partial<NoteDetail>) {
    if (!note) return;
    const next = { ...note, ...patch };
    setNote(next);
    setNotes((list) =>
      list.map((item) =>
        item.id === next.id
          ? {
              ...item,
              title: next.title,
              body: next.content,
              tags: next.tags,
              type: next.type,
              outgoingIDs: undefined,
            }
          : item,
      ),
    );
    post("change", { note: encode(next) });
  }
  function open(id: string, anchor?: string) {
    post("openNote", { id: id + (anchor ? "#" + anchor : "") });
  }
  function commitTag(raw = tagDraft) {
    const value = raw.trim().replace(/^#+/, "").trim();
    if (value && note && !note.tags.includes(value))
      change({ tags: [...note.tags, value] });
    setTagDraft("");
  }
  if (!note)
    return (
      <div className="flex h-full items-center justify-center">
        <div className="station-panel flex flex-col gap-4">
          <span>选择笔记类型开始记录</span>
          <NoteCreateButtons
            onCreate={(type) => {
              setEditing(true);
              post("createNote", { noteType: type });
            }}
          />
          {status && (
            <span role="status" className="text-xs">
              {status}
            </span>
          )}
        </div>
      </div>
    );
  return (
    <div className="flex h-full min-h-0 flex-col gap-2 px-2 pb-2 pt-0">
      <div className="relative flex min-h-0 flex-1 gap-2">
        {!zen && (
          <aside
            id="note-list"
            className="station-panel flex w-52 shrink-0 min-h-0 flex-col gap-2 overflow-hidden"
          >
            <NoteCreateButtons
              className="w-full"
              onCreate={(type) => {
                commitTag();
                setEditing(true);
                post("createNote", { noteType: type });
              }}
            />
            <SearchInput
              value={listQuery}
              onChange={setListQuery}
              placeholder="搜索笔记"
            />
            {filteredNotes.length ? <VirtualNoteList items={filteredNotes} currentID={note.id} onOpen={(id) => { if (id !== note.id) { commitTag(); open(id); } }} /> : <div className="min-h-0 flex-1 overflow-y-auto pr-2"><EmptyCard variant="plain" icon="notes">{listQuery ? "没有匹配的笔记" : "暂无笔记"}</EmptyCard></div>}
          </aside>
        )}
        <section className="station-panel flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden">
          <header className="-mt-1 mb-2 flex shrink-0 items-center gap-2">
            <input
              readOnly={!editing}
              value={note.title}
              onChange={(e) => change({ title: e.target.value })}
              className="min-w-0 flex-1 select-text bg-transparent text-base font-semibold outline-none"
            />
            <div className="flex shrink-0 gap-2">
              <Tooltip content="删除笔记">
                <button
                  className="station-icon-button"
                  aria-label="删除笔记"
                  onClick={() => setConfirmDelete(true)}
                >
                  <Icon name="trash" className="size-4" />
                </button>
              </Tooltip>
              <Tooltip content={editing ? "预览笔记" : "编辑笔记"}>
                <button
                  id="mode"
                  className="station-icon-button"
                  aria-label={editing ? "预览笔记" : "编辑笔记"}
                  onClick={() => {
                    commitTag();
                    setEditing(!editing);
                  }}
                >
                  <Icon
                    name={editing ? "preview" : "edit"}
                    className="size-4"
                  />
                </button>
              </Tooltip>
              <Tooltip content="专注模式">
                <button
                  className="station-icon-button"
                  onClick={() => setZen(!zen)}
                >
                  <Icon
                    name={zen ? "focus-exit" : "focus"}
                    className="size-4"
                  />
                </button>
              </Tooltip>
            </div>
          </header>
          <NoteMetadata
            note={note}
            editing={editing}
            tagDraft={tagDraft}
            onTagDraftChange={setTagDraft}
            onCommitTag={commitTag}
            onRemoveTag={(tag) =>
              change({ tags: note.tags.filter((value) => value !== tag) })
            }
            onInsertTemplate={(text) => ref.current?.insert(text)}
          />
          <div
            className={
              note.type === "excalidraw"
                ? "flex min-h-0 flex-1"
                : "pointer-events-none absolute invisible"
            }
            aria-hidden={note.type !== "excalidraw"}
          >
            {(canvasMounted || note.type === "excalidraw") && (
              <ExcalidrawCanvas
                documentKey={note.id}
                value={
                  note.type === "excalidraw"
                    ? note.content
                    : '{"elements":[],"appState":{},"files":{}}'
                }
                readonly={!editing || note.type !== "excalidraw"}
                onChange={(content) => {
                  if (note.type === "excalidraw") change({ content });
                }}
              />
            )}
          </div>
          {note.type === "markdown" && (
            <div className="relative flex min-h-0 flex-1 gap-2">
              <div className="h-full min-h-0 min-w-0 flex-1" hidden={!editing}>
                <MarkdownEditor
                  active={editing}
                  ref={ref}
                  documentKey={note.id}
                  value={note.content}
                  onChange={(content) => change({ content })}
                  onAttachmentUpload={upload}
                  linkSuggestions={notes.filter(
                    (n) =>
                      n.id !== note.id &&
                      (!query ||
                        n.title.toLowerCase().includes(query.toLowerCase())),
                  )}
                  onLinkQueryChange={setQuery}
                  onScrollLine={(line, edge) => {
                    if (editing) previewRef.current?.scrollToLine(line, edge);
                  }}
                />
              </div>
              <div
                className={
                  "h-full min-h-0 min-w-0 flex-1 " +
                  (editing ? "border-l border-white/10 pl-2" : "")
                }
              >
                <Reading
                  content={deferred}
                  preview={previewRef}
                  onOpen={open}
                />
              </div>
            </div>
          )}
          <div className="shrink-0 px-1 pt-1 text-right text-xs text-station-subtle">
            {note.type === "markdown" ? `${wordCount} 字` : "画板"}
          </div>
        </section>
        {!zen && (
          <aside className="station-panel flex min-h-0 w-60 shrink-0 flex-col overflow-hidden">
            <div className="station-segmented mb-2 shrink-0">
              {(note.type === "markdown"
                ? ["outline", "links"]
                : ["links"]
              ).map((tab) => (
                <button
                  key={tab}
                  className={
                    "station-segmented-item " +
                    (note.type === "excalidraw" || sideTab === tab
                      ? "station-segmented-item-active"
                      : "")
                  }
                  onClick={() => setSideTab(tab)}
                >
                  {tab === "outline" ? "目录" : "链接"}
                </button>
              ))}
            </div>
            {note.type === "markdown" && sideTab === "outline" ? (
              <OutlinePane
                headings={headings}
                onSelectHeading={(offset) => {
                  document
                    .querySelector(`[data-heading-offset="${offset}"]`)
                    ?.scrollIntoView({ behavior: "smooth", block: "center" });
                }}
              />
            ) : (
              <NoteLinksPane
                incomingOnly={note.type === "excalidraw"}
                noteId={note.id}
                content={note.content}
                notes={notes}
                onOpenNote={open}
              />
            )}
            <NotePropertiesPanel
              note={note}
              editing={editing}
              onChange={(properties) => change({ properties })}
            />
          </aside>
        )}
      </div>
      {confirmDelete && (
        <div
          className="fixed inset-0 z-[110] flex items-center justify-center bg-black/40"
          onClick={() => setConfirmDelete(false)}
        >
          <div
            role="alertdialog"
            aria-modal="true"
            aria-label="删除笔记"
            className="station-panel flex max-w-sm flex-col gap-4 p-4"
            onClick={(event) => event.stopPropagation()}
            onKeyDown={(event) => {
              if (event.key === "Escape") setConfirmDelete(false);
            }}
          >
            <span>删除「{note.title || "未命名笔记"}」？删除后无法恢复。</span>
            <div className="flex justify-end gap-2">
              <button
                autoFocus
                className="station-button-secondary"
                onClick={() => setConfirmDelete(false)}
              >
                取消
              </button>
              <button
                className="station-button-secondary"
                onClick={() => {
                  setConfirmDelete(false);
                  post("deleteNote");
                }}
              >
                删除
              </button>
            </div>
          </div>
        </div>
      )}
      {status && (
        <div
          role="status"
          className="station-popup fixed right-4 top-4 z-[100] flex max-w-sm items-center gap-2 p-3 text-xs"
        >
          <span>{status}</span>
          <button
            className="station-icon-button"
            aria-label="关闭提示"
            onClick={() => statusSetter("")}
          >
            <Icon name="close" className="size-3.5" />
          </button>
        </div>
      )}
    </div>
  );
}
const root = createRoot(document.getElementById("app")!);
root.render(<App />);
(window as any).notesApp = {
  searchResult: (request: string, ids: string[] | null) =>
    deliverSearch(request, ids),
  clear: () => clear(),
  catalog: (list: Card[]) => updateCatalog(list),
  load: (data: Stored, list: Card[], heading?: string) =>
    load(data, list, heading),
  insert: (text: string) => insert(text),
  status: (text: string) => setStatus(text),
  attachmentResult: (id: string, text: string, error?: string) => {
    const request = requests.get(id);
    requests.delete(id);
    if (error) request?.reject(new Error(error));
    else request?.resolve(text);
  },
  dispose: () => {
    requests.forEach((r) => r.resolve(null));
    requests.clear();
    root.unmount();
  },
  probe: () => ({
    ready: !!current,
    body: current?.content,
    webEditor: !!document.querySelector(".cm-editor"),
    mermaid: true,
  }),
};
