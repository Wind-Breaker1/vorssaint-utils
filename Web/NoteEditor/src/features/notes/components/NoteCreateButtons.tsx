import type { NoteType } from "@/contracts";
import { Icon } from "@/shared/components/Icon";
import { Tooltip } from "@/shared/components/Tooltip";

type Props = {
  onCreate: (type: NoteType) => void;
  disabled?: boolean;
  className?: string;
};

/** Two explicit entry points; note creation has no dropdown variant. */
export function NoteCreateButtons({
  onCreate,
  disabled = false,
  className = "",
}: Props): React.JSX.Element {
  return (
    <div className={`flex shrink-0 items-center gap-2 ${className}`}>
      <Tooltip content="新增 Markdown 笔记" className="min-w-0 flex-1">
        <button
          type="button"
          disabled={disabled}
          className="station-button-secondary flex w-full min-w-0 items-center justify-center gap-1 !px-1"
          onClick={() => onCreate("markdown")}
        >
          <Icon name="notes" className="size-3.5 shrink-0" />
          <span>Markdown</span>
        </button>
      </Tooltip>
      <Tooltip content="新增 Excalidraw 笔记" className="min-w-0 flex-1">
        <button
          type="button"
          disabled={disabled}
          className="station-button-secondary flex w-full min-w-0 items-center justify-center gap-1 !px-1"
          onClick={() => onCreate("excalidraw")}
        >
          <Icon name="excalidraw" className="size-3.5 shrink-0" />
          <span>Excalidraw</span>
        </button>
      </Tooltip>
    </div>
  );
}
