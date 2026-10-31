import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { Popup } from '@/shared/components/Popup';
import { Icon, type IconName } from '@/shared/components/Icon';
import { EmptyCard } from '@/shared/components/EmptyCard';

export type SelectOption = { value: string; label: string; icon?: IconName };
type Props = {
	value: string;
	options: SelectOption[];
	placeholder?: string;
	onChange: (value: string) => void;
	className?: string;
	triggerClassName?: string;
	disabled?: boolean;
	variant?: 'default' | 'minimal';
	/** 触发器高度：default 为 32px，sm 为 24px（用于统计卡片等紧凑区域）。 */
	size?: 'default' | 'sm';
	/** 开启后，选中值与回落值不同时在触发器右侧显示常驻清除按钮。 */
	clearable?: boolean;
	/** 清除后回落的值；缺省为空字符串（空值即不过滤/全部）。 */
	clearValue?: string;
	/** 开启后触发器本身变为可输入（参考 TDesign 可搜索下拉），输入即过滤选项，适合项目、标签等动态长列表。 */
	searchable?: boolean;
	'aria-label'?: string;
};

/** 按关键词过滤选项，大小写不敏感，空关键词保留完整列表。 */
export function filterSelectOptions(options: SelectOption[], keyword: string): SelectOption[] {
	const normalized = keyword.trim().toLowerCase();
	if (!normalized) return options;
	return options.filter((option) => option.label.toLowerCase().includes(normalized));
}

/** 无原生 select 的统一下拉组件，面板按内容撑开并限制最大宽度，支持键盘导航和点击外部关闭。 */
export function Select({
	value,
	options,
	placeholder,
	onChange,
	className = '',
	triggerClassName = '',
	disabled = false,
	variant = 'default',
	size = 'default',
	clearable = false,
	clearValue = '',
	searchable = false,
	'aria-label': ariaLabel,
}: Props): React.JSX.Element {
	const [open, setOpen] = useState(false);
	const [searchText, setSearchText] = useState('');
	const [activeValue, setActiveValue] = useState<string | null>(null);
	const listId = useId();
	const triggerRef = useRef<HTMLElement | null>(null);
	const inputRef = useRef<HTMLInputElement>(null);
	const close = useCallback(() => {
		setOpen(false);
		setSearchText('');
		setActiveValue(null);
	}, []);
	useEffect(() => {
		if (disabled) close();
	}, [close, disabled]);
	useEffect(() => {
		// 展开时聚焦触发器内的输入框，让搜索直接从这里开始（弹层首帧 visibility:hidden 不影响触发器）。
		if (!open || !searchable) return;
		const frame = requestAnimationFrame(() => inputRef.current?.focus());
		return () => cancelAnimationFrame(frame);
	}, [open, searchable]);
	const visibleOptions = useMemo(
		() => (searchable ? filterSelectOptions(options, searchText) : options),
		[options, searchable, searchText],
	);
	const activeIndex = visibleOptions.findIndex((option) => option.value === activeValue);
	const activeId = open && activeIndex >= 0 ? `${listId}-${activeIndex}` : undefined;
	const selected = useMemo(() => options.find((option) => option.value === value), [options, value]);
	useEffect(() => {
		if (activeId) document.getElementById(activeId)?.scrollIntoView({ block: 'nearest' });
	}, [activeId]);
	const label = ariaLabel ?? placeholder ?? '选择选项';
	// 无选中值或已等于回落值时没有可清除的内容，此时保留下拉箭头以提示可展开。
	const canClear = clearable && !disabled && Boolean(selected) && value !== clearValue;
	/** 把选中值重置为回落值，让调用方的筛选或表单回到初始状态。 */
	function clear(): void {
		(inputRef.current ?? triggerRef.current)?.focus();
		close();
		onChange(clearValue);
	}
	/** Return focus before notifying callers, which may deliberately focus another field. */
	function choose(option: SelectOption): void {
		(inputRef.current ?? triggerRef.current)?.focus();
		close();
		onChange(option.value);
	}
	/** Opening preserves the committed selection without committing a keyboard highlight. */
	function openPanel(): void {
		setOpen(true);
		setSearchText('');
		setActiveValue(selected?.value ?? null);
	}
	const triggerClasses = `${variant === 'minimal' ? 'station-input-trigger-minimal' : 'station-input-trigger'} ${size === 'sm' ? 'station-input-trigger-sm' : ''} ${triggerClassName}`;
	return (
		<div
			className={`relative ${className}`}
			onBlur={(event) => {
				if (!event.currentTarget.contains(event.relatedTarget)) close();
			}}
		>
			{searchable ? (
				<div
					ref={(node) => {
						// 两种触发器形态共享同一个锚点引用，供 Popup 定位使用。
						triggerRef.current = node;
					}}
					className={`${triggerClasses} ${disabled ? 'cursor-not-allowed opacity-60' : 'cursor-text'}`}
					onClick={() => {
						if (disabled) return;
						if (!open) openPanel();
						inputRef.current?.focus();
					}}
				>
					<input
						ref={inputRef}
						type="text"
						role="combobox"
						aria-expanded={open}
						aria-controls={open ? listId : undefined}
						aria-activedescendant={activeId}
						aria-autocomplete="list"
						aria-label={label}
						disabled={disabled}
						// 关闭态显示选中值，展开后输入即过滤；关闭由 close() 统一清空搜索词。
						value={open ? searchText : (selected?.label ?? '')}
						placeholder={open ? (placeholder ?? '输入关键词过滤') : (placeholder ?? '请选择')}
						onChange={(event) => {
							setSearchText(event.target.value);
							setActiveValue(null);
							setOpen(true);
						}}
						className={`min-w-0 flex-1 select-text bg-transparent p-0 text-xs text-station-text outline-none placeholder:text-station-subtle ${canClear ? 'pr-4' : ''}`}
					/>
					{!canClear && (
						<Icon name="chevron-down" className={`size-3.5 shrink-0 text-station-subtle transition ${open ? 'rotate-180' : ''}`} />
					)}
				</div>
			) : (
				<button
					type="button"
					ref={(node) => {
						// 两种触发器形态共享同一个锚点引用，供 Popup 定位使用。
						triggerRef.current = node;
					}}
					disabled={disabled}
					className={triggerClasses}
					role="combobox"
					aria-expanded={open}
					aria-haspopup="listbox"
					aria-controls={open ? listId : undefined}
					aria-activedescendant={activeId}
					aria-label={ariaLabel ?? placeholder ?? selected?.label ?? label}
					onClick={() => (open ? close() : openPanel())}
				>
					<span className={`min-w-0 truncate ${canClear ? 'pr-4' : ''} ${selected ? '' : 'text-station-subtle'}`}>
						{selected?.label ?? placeholder ?? ''}
					</span>
					{!canClear && (
						<Icon name="chevron-down" className={`size-3.5 shrink-0 text-station-subtle transition ${open ? 'rotate-180' : ''}`} />
					)}
				</button>
			)}
			{canClear && (
				<button
					type="button"
					aria-label="清除选择"
					/* 常驻清除按钮：垂直居中的小方块，不能撑满触发器高度（否则 hover 底色会与圆角边沿割裂）。 */
					className={`absolute top-1/2 grid size-4 -translate-y-1/2 cursor-pointer place-items-center rounded-xl text-station-muted transition hover:bg-white/10 hover:text-station-text ${variant === 'minimal' ? 'right-1' : 'right-1.5'}`}
					onClick={clear}
				>
					<Icon name="close" className="size-3.5" />
				</button>
			)}
			<Popup
				open={open}
				anchorRef={triggerRef}
				onRequestClose={close}
				matchMinWidth
				className="station-popup flex max-h-75 w-max max-w-50 flex-col p-2"
			>
				<div id={listId} role="listbox" aria-label={label} className="flex flex-col gap-1">
					{visibleOptions.map((option, index) => (
						<button
							key={option.value}
							id={`${listId}-${index}`}
							type="button"
							role="option"
							tabIndex={-1}
							aria-selected={option.value === value}
							className={`flex w-full items-center gap-2 rounded-xl px-2 py-2 text-left text-xs text-station-text transition hover:bg-white/10 ${option.value === value ? 'bg-station-accent/20' : ''} ${index === activeIndex ? 'bg-white/10 ring-1 ring-inset ring-white/20' : ''}`}
							onMouseDown={(event) => event.preventDefault()}
							onClick={() => choose(option)}
						>
							{option.icon && <Icon name={option.icon} className="size-3.5 shrink-0" />}
							{option.label}
						</button>
					))}
					{!visibleOptions.length && (
						<EmptyCard variant="plain" icon="search">
							无匹配选项
						</EmptyCard>
					)}
				</div>
			</Popup>
		</div>
	);
}
