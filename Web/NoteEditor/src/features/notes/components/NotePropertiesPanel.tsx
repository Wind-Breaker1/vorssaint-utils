import { useCallback, useEffect, useRef, useState } from 'react';
import type { NoteDetail, NoteProperty, NotePropertyType, NotePropertyValue } from '@/contracts';
import { Checkbox } from '@/shared/components/Checkbox';
import { DatePicker } from '@/shared/components/DatePicker';
import { Icon, type IconName } from '@/shared/components/Icon';
import { Popup } from '@/shared/components/Popup';
import { EmptyCard } from '@/shared/components/EmptyCard';
import { ScrollContainer } from '@/shared/components/ScrollContainer';
import { Tooltip } from '@/shared/components/Tooltip';
import { toast } from '@/shared/toast/toast';

const typeOptions: { value: NotePropertyType; label: string }[] = [
	{ value: 'text', label: '文本' },
	{ value: 'number', label: '数字' },
	{ value: 'checkbox', label: '复选框' },
	{ value: 'date', label: '日期' },
	{ value: 'list', label: '列表' },
];
const emptyValues: Record<NotePropertyType, NotePropertyValue> = { text: '', number: 0, checkbox: false, date: '', list: [] };
const propertyIcons: Record<NotePropertyType, IconName> = {
	text: 'property-text',
	number: 'property-number',
	checkbox: 'property-checkbox',
	date: 'property-date',
	list: 'property-list',
};

type Props = { note: NoteDetail; editing: boolean; onChange: (properties: NoteProperty[]) => void };
export function NotePropertiesPanel({ note, editing, onChange }: Props): React.JSX.Element {
	const [listDraft, setListDraft] = useState<{ property: NoteProperty; value: string } | null>(null);
	const [focusPropertyIndex, setFocusPropertyIndex] = useState<number | null>(null);
	const [openMenuIndex, setOpenMenuIndex] = useState<number | null>(null);
	const propertyInputRefs = useRef<Record<number, HTMLInputElement | null>>({});
	const propertyMenuRefs = useRef<Record<number, { current: HTMLButtonElement | null }>>({});
	const closeMenu = useCallback(() => setOpenMenuIndex(null), []);
	function getPropertyMenuRef(index: number): { current: HTMLButtonElement | null } {
		// 为每一行复用稳定 ref，避免 Popup 每次渲染重新绑定定位监听。
		return (propertyMenuRefs.current[index] ??= { current: null });
	}
	useEffect(() => {
		// 新增属性后把焦点交给对应的属性名输入框。
		if (focusPropertyIndex === null) return;
		propertyInputRefs.current[focusPropertyIndex]?.focus();
		setFocusPropertyIndex(null);
	}, [focusPropertyIndex, note.properties.length]);
	function patch(index: number, value: Partial<NoteProperty>): void {
		// 属性面板只替换目标行，保持其他属性引用和输入状态稳定。
		onChange(note.properties.map((property, propertyIndex) => (propertyIndex === index ? { ...property, ...value } : property)));
	}
	function addProperty(): void {
		const incompleteIndex = note.properties.findIndex((property) => !property.key.trim() || !isPropertyValueComplete(property));
		if (incompleteIndex >= 0) {
			propertyInputRefs.current[incompleteIndex]?.focus();
			toast('请先填写当前属性的名称和值');
			return;
		}
		// 新属性从文本类型和空值开始，随后自动聚焦名称输入框。
		const nextIndex = note.properties.length;
		onChange([...note.properties, { id: crypto.randomUUID(), key: '', type: 'text', value: '' }]);
		setFocusPropertyIndex(nextIndex);
	}
	function isPropertyValueComplete(property: NoteProperty): boolean {
		if (property.type === 'checkbox') return typeof property.value === 'boolean';
		if (property.type === 'number') return typeof property.value === 'number' && Number.isFinite(property.value);
		if (property.type === 'list') return Array.isArray(property.value) && property.value.length > 0 && property.value.every((item) => typeof item === 'string' && item.trim().length > 0);
		return typeof property.value === 'string' && property.value.trim().length > 0;
	}
	function removeProperty(index: number): void {
		// 属性删除立即更新草稿，不需要二次确认。
		onChange(note.properties.filter((_, propertyIndex) => propertyIndex !== index));
	}
	function changeType(index: number, type: NotePropertyType): void {
		// 切换类型时重置为该类型的安全初始值，避免旧值类型不匹配。
		patch(index, { type, value: emptyValues[type] });
	}
	function updateValue(index: number, property: NoteProperty, value: string): void {
		// 输入值在进入草稿前转换为契约要求的实际类型。
		if (property.type === 'number') patch(index, { value: Number.isFinite(Number(value)) ? Number(value) : 0 });
		else if (property.type === 'checkbox') patch(index, { value: value === 'true' });
		else patch(index, { value });
	}
	function addListItem(index: number, property: NoteProperty): void {
		// 列表属性去除空值并去重，按 Enter 后追加到当前属性。
		const value = (listDraft?.property === property ? listDraft.value : '').trim();
		if (!value) return;
		const items: string[] = Array.isArray(property.value) ? property.value.filter((item): item is string => typeof item === 'string') : [];
		if (!items.includes(value)) patch(index, { value: [...items, value] });
		setListDraft({ property, value: '' });
	}
	function removeListItem(index: number, property: NoteProperty, itemIndex: number): void {
		// 只删除列表中的指定项，不影响其他属性或列表项。
		if (!Array.isArray(property.value)) return;
		const items: string[] = property.value.filter((item): item is string => typeof item === 'string');
		patch(index, { value: items.filter((_, valueIndex) => valueIndex !== itemIndex) });
	}
	return (
		<section className="mt-2 flex max-h-75 min-h-0 select-none flex-col rounded-lg border border-white/10 p-1.5">
			<ScrollContainer layout="stack">
				{note.properties.map((property, index) => (
					<div key={property.id ?? index} className="relative min-w-0 border-b border-white/10 pb-1.5 last:border-0 last:pb-0">
						<div className="flex min-w-0 items-center gap-1">
							<button
								type="button"
								ref={getPropertyMenuRef(index)}
								className={`grid size-6 shrink-0 place-items-center rounded-lg text-station-subtle transition hover:bg-white/10 hover:text-station-text ${openMenuIndex === index ? 'bg-white/10 text-station-text' : ''}`}
								disabled={!editing}
								aria-label={`修改${property.key || '未命名'}属性类型`}
								onClick={() => setOpenMenuIndex((current) => (current === index ? null : index))}
							>
								<Icon name={propertyIcons[property.type]} className="size-3.5" />
							</button>
							<input
								ref={(element) => {
									propertyInputRefs.current[index] = element;
								}}
								className="h-6 min-w-0 flex-1 select-text bg-transparent px-1 text-xs font-medium outline-none placeholder:text-station-subtle"
								value={property.key}
								readOnly={!editing}
								onChange={(event) => patch(index, { key: event.target.value })}
								placeholder="属性名"
							/>
							{editing && (
								<Tooltip content="删除属性">
									<button
										type="button"
										aria-label={`删除${property.key || '未命名'}属性`}
										className="station-button-delete"
										onClick={() => removeProperty(index)}
									>
										<Icon name="trash" className="size-3.5" />
									</button>
								</Tooltip>
							)}
						</div>
						<Popup
							open={openMenuIndex === index}
							anchorRef={getPropertyMenuRef(index)}
							onRequestClose={closeMenu}
							className="station-popup w-44 p-2"
						>
							<div className="flex flex-col gap-1 text-xs">
								<p className="px-2 py-2 station-text-caption">属性类型</p>
								{typeOptions.map((option) => (
									<button
										type="button"
										key={option.value}
										className={`flex items-center gap-2 rounded-xl px-2 py-2 text-left text-station-text transition hover:bg-white/10 ${property.type === option.value ? 'bg-station-accent/20' : ''}`}
										onClick={() => {
											changeType(index, option.value);
											setOpenMenuIndex(null);
										}}
									>
										<Icon name={propertyIcons[option.value]} className="size-3.5" />
										{option.label}
									</button>
								))}
							</div>
						</Popup>
						{property.type === 'checkbox' ? (
							<label className="mt-1 flex h-8 items-center gap-2 rounded-xl px-2 text-xs text-station-muted">
								<Checkbox checked={property.value === true} disabled={!editing} onChange={(checked) => patch(index, { value: checked })} />
								{property.value === true ? '已勾选' : '未勾选'}
							</label>
						) : property.type === 'list' ? (
										<div className="mt-1 flex min-h-7 w-full flex-wrap items-center gap-1 rounded-lg border border-white/10 bg-white/5 px-1.5 py-1">
								{(Array.isArray(property.value) ? property.value : []).map((item, itemIndex) => (
									<span
										key={`${item}-${itemIndex}`}
										className="inline-flex max-w-full items-center gap-1 rounded-xl bg-station-accent/20 px-2 py-0 text-xs"
									>
										<span className="select-text truncate">{item}</span>
										{editing && (
											<button
												type="button"
												aria-label={`移除列表项 ${item}`}
												className="text-station-text hover:text-station-text"
												onClick={() => removeListItem(index, property, itemIndex)}
											>
												×
											</button>
										)}
									</span>
								))}
								{editing && (
									<input
										className="h-6 min-w-16 flex-1 select-text bg-transparent text-xs outline-none placeholder:text-station-subtle"
										value={listDraft?.property === property ? listDraft.value : ''}
										onChange={(event) => setListDraft({ property, value: event.target.value })}
										onKeyDown={(event) => {
											if (event.key === 'Enter') {
												event.preventDefault();
												addListItem(index, property);
											}
										}}
										placeholder="添加项目，按 Enter"
									/>
								)}
							</div>
						) : property.type === 'date' ? (
							<DatePicker
								value={typeof property.value === 'string' ? property.value : ''}
								disabled={!editing}
								className="mt-1 w-full"
								onChange={(value) => patch(index, { value })}
							/>
						) : (
							<input
								className="station-input-field select-text mt-1 w-full text-xs"
								type={property.type === 'number' ? 'number' : 'text'}
								value={String(property.value)}
								readOnly={!editing}
								onChange={(event) => updateValue(index, property, event.target.value)}
								placeholder={`输入${typeOptions.find((item) => item.value === property.type)?.label ?? ''}`}
							/>
						)}
					</div>
				))}
				{!note.properties.length && !editing && (
					<EmptyCard variant="plain" icon="property-list">
						暂无属性
					</EmptyCard>
				)}
			</ScrollContainer>
			{editing && (
				<button
					type="button"
					className="mt-1 rounded-lg border border-dashed border-station-accent/40 py-1.5 text-center text-xs text-station-text hover:bg-white/5 hover:text-station-text"
					onClick={addProperty}
				>
					＋ 添加属性
				</button>
			)}
		</section>
	);
}
