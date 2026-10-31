import { Icon } from "@/shared/components/Icon";
import { EmptyCard } from "@/shared/components/EmptyCard";
import { ScrollContainer } from "@/shared/components/ScrollContainer";
import { extractNoteLinks } from "../noteLinks";
type LinkRow = {
  id: string;
  title: string;
  onOpen: () => void;
};

/**
 * 上下同构的一块面板：固定标题栏 + 独立滚动的列表区，复用父级面板的表面。
 * 两块各占一半高度，靠间隙而不是分隔线区分。
 */
function LinkSection({
  title,
  total,
  emptyText,
  rows,
}: {
  title: string;
  total: number;
  emptyText: string;
  rows: LinkRow[];
}): React.JSX.Element {
  return (
    <section className="flex min-h-0 flex-1 flex-col gap-2">
      <header className="flex shrink-0 items-center justify-between station-text-caption">
        <span>{title}</span>
        <span>{total}</span>
      </header>
      <ScrollContainer>
        {rows.length ? (
          rows.map((row) => (
            <div key={row.id} className="flex items-center gap-1">
              <button
                type="button"
                className="station-list-item flex w-full min-w-0 items-center gap-2"
                onClick={row.onOpen}
              >
                <Icon
                  name="notes"
                  className="size-3 shrink-0 text-station-subtle"
                />
                <span className="truncate text-xs text-station-text">
                  {row.title}
                </span>
              </button>
            </div>
          ))
        ) : (
          <EmptyCard variant="plain" icon="notes">
            {emptyText}
          </EmptyCard>
        )}
      </ScrollContainer>
    </section>
  );
}

export function NoteLinksPane({
  noteId,
  content,
  notes,
  onOpenNote,
  incomingOnly = false,
}: {
  incomingOnly?: boolean;
  noteId: string;
  content: string;
  notes: { id: string; title: string; body: string; outgoingIDs?: string[] }[];
  onOpenNote: (id: string, heading?: string) => void;
}) {
  const currentId = noteId.toLowerCase();
  const knownIds = new Set(notes.map((note) => note.id.toLowerCase()));
  const outgoing = incomingOnly
    ? []
    : extractNoteLinks(content).filter(
        (l) => l.id !== currentId && knownIds.has(l.id),
      );
  const backlinks = notes.filter(
    (n) =>
      n.id.toLowerCase() !== currentId &&
      (n.outgoingIDs
        ? n.outgoingIDs.some((id) => id.toLowerCase() === currentId)
        : !n.body.trimStart().startsWith("{") &&
          extractNoteLinks(n.body).some((l) => l.id === currentId)),
  );
  return (
    <div className="flex min-h-0 flex-1 flex-col gap-2">
      <LinkSection
        title="入链 · 引用当前"
        total={backlinks.length}
        emptyText="还没有笔记链接到这里"
        rows={backlinks.map((n) => ({
          id: n.id,
          title: n.title,
          onOpen: () => onOpenNote(n.id),
        }))}
      />
      {!incomingOnly && (
        <LinkSection
          title="出链 · 当前引用"
          total={outgoing.length}
          emptyText="还没有引用其他笔记"
          rows={outgoing.map((n) => ({
            id: n.id,
            title:
              notes.find((item) => item.id.toLowerCase() === n.id)?.title ||
              n.label ||
              "未命名笔记",
            onOpen: () => onOpenNote(n.id, n.heading ?? undefined),
          }))}
        />
      )}
    </div>
  );
}
