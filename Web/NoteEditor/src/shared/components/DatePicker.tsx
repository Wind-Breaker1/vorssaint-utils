import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Popup } from '@/shared/components/Popup';
import { Icon } from '@/shared/components/Icon';
import { Tooltip } from '@/shared/components/Tooltip';
import { formatDate, getMonthDays, parseDate, startOfMonth } from '@/shared/components/dateUtils';

type Props = {
	value: string;
	onChange: (value: string) => void;
	disabled?: boolean;
	className?: string;
	triggerClassName?: string;
};
const weekDays = ['一', '二', '三', '四', '五', '六', '日'];
const monthFormatter = new Intl.DateTimeFormat('zh-CN', { year: 'numeric', month: 'long' });

/** 无原生 date input 的统一日期选择器，使用轻量自绘月历。 */
export function DatePicker({ value, onChange, disabled = false, className = '', triggerClassName = '' }: Props): React.JSX.Element {
	const selected = parseDate(value);
	const [open, setOpen] = useState(false);
	const [month, setMonth] = useState(() => startOfMonth(selected ?? new Date()));
	const triggerRef = useRef<HTMLButtonElement>(null);
	useEffect(() => {
		// 外部值变化时同步当前月份，保证编辑属性时日历打开在正确月份。
		if (selected) setMonth(startOfMonth(selected));
	}, [value]);
	const close = useCallback(() => setOpen(false), []);
	const days = useMemo(() => {
		// 生成以周一为起点的月历网格，前置空位用于对齐星期。
		return getMonthDays(month);
	}, [month]);
	function moveMonth(offset: number): void {
		// 始终定位到目标月份第一天，避免当前日期导致跨月偏移。
		setMonth((current) => new Date(current.getFullYear(), current.getMonth() + offset, 1));
	}
	return (
		<div className={`relative ${className}`}>
			<button
				type="button"
				ref={triggerRef}
				disabled={disabled}
				className={`station-input-trigger min-w-0 ${disabled ? 'cursor-not-allowed opacity-60' : ''} ${value ? 'pr-9' : ''} ${triggerClassName}`}
				onClick={() => setOpen((current) => !current)}
			>
				<span className="min-w-0 truncate">{selected ? `${selected.getFullYear()}年${selected.getMonth() + 1}月${selected.getDate()}日` : '年 / 月 / 日'}</span>
				{!value && <Icon name="calendar" className="size-3.5 shrink-0 text-station-subtle" />}
			</button>
			{value && (
				<button
					type="button"
					aria-label="清空日期"
					disabled={disabled}
					className="absolute right-1.5 top-1/2 z-10 grid size-4 -translate-y-1/2 place-items-center rounded-md bg-transparent text-station-subtle hover:bg-white/10 hover:text-station-text disabled:opacity-50"
					onClick={() => {
						onChange('');
						setOpen(false);
					}}
				>
					<Icon name="close" className="size-3.5" />
				</button>
			)}
			<Popup open={open} anchorRef={triggerRef} onRequestClose={close} matchWidth className="station-popup min-w-60 p-2">
				<header className="flex items-center gap-0">
					<Tooltip content="上一年">
						<button type="button" className="station-icon-button size-6" onClick={() => moveMonth(-12)}>
							<Icon name="double-chevron-left" className="size-3" />
						</button>
					</Tooltip>
					<Tooltip content="上个月">
						<button type="button" className="station-icon-button size-6" onClick={() => moveMonth(-1)}>
							<Icon name="chevron-left" className="size-3.5" />
						</button>
					</Tooltip>
					<strong className="min-w-0 flex-1 text-center text-xs text-station-text">{monthFormatter.format(month)}</strong>
					<Tooltip content="下个月">
						<button type="button" className="station-icon-button size-6" onClick={() => moveMonth(1)}>
							<Icon name="chevron-right" className="size-3.5" />
						</button>
					</Tooltip>
					<Tooltip content="下一年">
						<button type="button" className="station-icon-button size-6" onClick={() => moveMonth(12)}>
							<Icon name="double-chevron-right" className="size-3" />
						</button>
					</Tooltip>
				</header>
				<div className="mt-2 grid grid-cols-7 text-center station-text-caption">
					{weekDays.map((day) => (
						<span key={day} className="py-0">
							{day}
						</span>
					))}
				</div>
				<div className="grid grid-cols-7 gap-0 text-center text-xs">
					{days.map((day, index) =>
						day ? (
							<button
								key={formatDate(day)}
								type="button"
								className={`grid aspect-square place-items-center rounded-xl text-station-text transition hover:bg-station-accent/20 ${value === formatDate(day) ? 'bg-station-accent' : ''}`}
								onClick={() => {
									onChange(formatDate(day));
									setOpen(false);
								}}
							>
								{day.getDate()}
							</button>
						) : (
							<span key={`blank-${index}`} />
						),
					)}
				</div>
				{value && (
					<button
						type="button"
						className="mt-2 w-full rounded-xl py-0 text-xs text-station-text hover:bg-white/10 hover:text-station-text"
						onClick={() => {
							onChange('');
							setOpen(false);
						}}
					>
						清除日期
					</button>
				)}
			</Popup>
		</div>
	);
}
