/**
 * Date helpers shared by the date picker and the review calendar.
 *
 * Dates in the UI are deliberately represented as local calendar dates rather
 * than timestamps. This avoids a date moving to the previous/next day when a
 * value is serialized in a different timezone.
 */

export type ISOWeek = { year: number; week: number };
export type ReviewPeriod = 'day' | 'week' | 'month' | 'quarter';
export type ReviewPeriodSelection = {
	period: ReviewPeriod;
	/** The date that identifies the selected period. */
	date: string;
	startDate: string;
	endDate: string;
	week?: number;
	weekYear?: number;
	month?: number;
	quarter?: number;
	year: number;
};

export function parseDate(value: string): Date | null {
	// Date 构造函数会自动溢出非法日期，因此需要回读年月日进行严格校验。
	const match = value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
	if (!match) return null;
	const year = Number(match[1]);
	const month = Number(match[2]);
	const day = Number(match[3]);
	const date = new Date(year, month - 1, day);
	return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day ? date : null;
}

export function formatDate(date: Date): string {
	return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

/** 返回指定时区中的日历日期，供跨设备共享的业务日期避免跟随设备时区漂移。 */
export function formatDateInTimeZone(date: Date, timeZone: string): string {
	const parts = new Intl.DateTimeFormat('en-CA', {
		timeZone,
		year: 'numeric',
		month: '2-digit',
		day: '2-digit',
	}).formatToParts(date);
	const value = (type: Intl.DateTimeFormatPartTypes): string => parts.find((part) => part.type === type)?.value ?? '';
	return `${value('year')}-${value('month')}-${value('day')}`;
}

/** 前端复盘与交易按中国日历日运转，与原生数据核心保持一致。 */
export function todayInChina(date: Date = new Date()): string {
	return formatDateInTimeZone(date, 'Asia/Shanghai');
}

export function startOfMonth(date: Date): Date {
	return new Date(date.getFullYear(), date.getMonth(), 1);
}

export function startOfWeek(date: Date): Date {
	const result = new Date(date.getFullYear(), date.getMonth(), date.getDate());
	result.setDate(result.getDate() - ((result.getDay() + 6) % 7));
	return result;
}

export function endOfWeek(date: Date): Date {
	const result = startOfWeek(date);
	result.setDate(result.getDate() + 6);
	return result;
}

/** ISO-8601 week number (Monday is the first day of the week). */
export function getISOWeek(date: Date): ISOWeek {
	// Use UTC for the arithmetic so daylight-saving transitions cannot change a
	// week number by a fraction of a day.
	const target = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
	const day = (target.getUTCDay() + 6) % 7;
	target.setUTCDate(target.getUTCDate() + 3 - day);
	const year = target.getUTCFullYear();
	const firstThursday = new Date(Date.UTC(year, 0, 4));
	const firstThursdayDay = (firstThursday.getUTCDay() + 6) % 7;
	firstThursday.setUTCDate(firstThursday.getUTCDate() + 3 - firstThursdayDay);
	const week = 1 + Math.round((target.getTime() - firstThursday.getTime()) / 604800000);
	return { year, week };
}

export function getQuarter(date: Date): number {
	return Math.floor(date.getMonth() / 3) + 1;
}

export function getReviewPeriodSelection(date: Date, period: ReviewPeriod): ReviewPeriodSelection {
	const value = formatDate(date);
	if (period === 'day')
		return {
			period,
			date: value,
			startDate: value,
			endDate: value,
			year: date.getFullYear(),
			month: date.getMonth() + 1,
			quarter: getQuarter(date),
		};
	if (period === 'month') {
		const start = new Date(date.getFullYear(), date.getMonth(), 1);
		const end = new Date(date.getFullYear(), date.getMonth() + 1, 0);
		return {
			period,
			date: value,
			startDate: formatDate(start),
			endDate: formatDate(end),
			year: date.getFullYear(),
			month: date.getMonth() + 1,
		};
	}
	if (period === 'quarter') {
		const quarter = getQuarter(date);
		const start = new Date(date.getFullYear(), (quarter - 1) * 3, 1);
		const end = new Date(date.getFullYear(), quarter * 3, 0);
		return { period, date: value, startDate: formatDate(start), endDate: formatDate(end), year: date.getFullYear(), quarter };
	}
	const info = getISOWeek(date);
	const monday = new Date(date);
	monday.setDate(date.getDate() - ((date.getDay() + 6) % 7));
	const sunday = new Date(monday);
	sunday.setDate(monday.getDate() + 6);
	return {
		period,
		date: value,
		startDate: formatDate(monday),
		endDate: formatDate(sunday),
		year: info.year,
		week: info.week,
		weekYear: info.year,
	};
}

/** Dates for the compact month grid, including leading/trailing blank cells. */
export function getMonthDays(month: Date): Array<Date | null> {
	const first = startOfMonth(month);
	const firstDay = (first.getDay() + 6) % 7;
	const count = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate();
	return [
		...Array(firstDay).fill(null),
		...Array.from({ length: count }, (_, index) => new Date(first.getFullYear(), first.getMonth(), index + 1)),
	];
}

/** Full Monday-Sunday rows used by the review calendar. */
export function getMonthWeeks(month: Date): Date[][] {
	const first = startOfWeek(startOfMonth(month));
	const last = endOfWeek(new Date(month.getFullYear(), month.getMonth() + 1, 0));
	const weeks: Date[][] = [];
	const cursor = new Date(first);
	while (cursor <= last) {
		weeks.push(
			Array.from({ length: 7 }, (_, index) => {
				const day = new Date(cursor);
				day.setDate(cursor.getDate() + index);
				return day;
			}),
		);
		cursor.setDate(cursor.getDate() + 7);
	}
	return weeks;
}
