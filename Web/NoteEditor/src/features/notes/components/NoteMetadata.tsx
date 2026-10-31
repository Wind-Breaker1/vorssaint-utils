import type { NoteDetail } from '@/contracts';
import { noteTemplates } from '@/features/notes/noteTemplates';
import { Icon } from '@/shared/components/Icon';
import { Select } from '@/shared/components/Select';
import { Tooltip } from '@/shared/components/Tooltip';

type Props = {
	note: NoteDetail;
	editing: boolean;
	tagDraft: string;
	onTagDraftChange: (value: string) => void;
	onCommitTag: (value: string) => void;
	onRemoveTag: (value: string) => void;
	onInsertTemplate: (content: string) => void;
};

/** Present note metadata while the draft owner controls all persistent values. */
export function NoteMetadata({
	note,
	editing,
	tagDraft,
	onTagDraftChange,
	onCommitTag,
	onRemoveTag,
	onInsertTemplate,
}: Props): React.JSX.Element {
	function handleTagKeyDown(event: React.KeyboardEvent<HTMLInputElement>): void {
		if (event.nativeEvent.isComposing) return;
		if (event.key === 'Enter') {
			event.preventDefault();
			onCommitTag(tagDraft);
		}
	}
	return (
		<div className="mb-2 flex select-none shrink-0 items-center gap-2 border-b border-white/10 pb-2">
			<Select
				value=""
				options={noteTemplates.map((item) => ({ value: item.id, label: item.name }))}
				placeholder="模板"
				disabled={!editing || note.type !== 'markdown' || Boolean(note.content.trim())}
				onChange={(value) => {
					const template = noteTemplates.find((item) => item.id === value);
					if (template) onInsertTemplate(template.content);
				}}
			/>
			<div className="flex min-h-8 min-w-0 flex-1 flex-wrap items-center gap-2 rounded-xl border border-white/10 bg-white/5 px-2 py-1 transition focus-within:border-station-accent/50">
				{note.tags.map((tag) => (
					<span key={tag} className={`station-tag-chip ${editing ? 'pl-2 pr-0' : 'px-2'}`}>
						<span className="select-text truncate">{tag}</span>
						{editing && (
							<Tooltip content={`移除标签 ${tag}`}>
								<button type="button" className="station-tag-chip-remove" aria-label={`移除标签 ${tag}`} onClick={() => onRemoveTag(tag)}>
									<Icon name="close" className="size-3.5" />
								</button>
							</Tooltip>
						)}
					</span>
				))}
				{editing ? (
					<input
						value={tagDraft}
						onChange={(event) => onTagDraftChange(event.target.value)}
						onKeyDown={handleTagKeyDown}
						onBlur={() => onCommitTag(tagDraft)}
						className="h-5 min-w-16 flex-1 select-text bg-transparent px-2 text-xs outline-none placeholder:text-station-subtle"
						placeholder={note.tags.length ? '' : '输入标签后回车'}
					/>
				) : (
					!note.tags.length && <span className="flex h-5 items-center px-2 station-text-caption">无标签</span>
				)}
			</div>
		</div>
	);
}
