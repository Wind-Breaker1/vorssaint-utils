import { Icon, type IconName } from './Icon';

type Props = {
	/** 与页面语义一致的线性图标，沿用全站同一套图标。 */
	icon: IconName;
	/**
	 * 材质开关，取代「同名不同物」的两套空态实现：
	 * - `card`（默认）：自带 `station-panel` 材质，用于**父级没有材质**的页面级空态。
	 * - `plain`：不带材质，用于**父级本身已是玻璃面板 / 滚动容器**的场合。
	 *
	 * 这不是样式偏好而是硬约束：frost 材质嵌套时内层对同一块背景再模糊一遍，视觉零增量、
	 * 白付一次整块采样。
	 */
	variant?: 'card' | 'plain';
	/**
	 * 默认撑满 flex 内容区、跨越所有网格列，并在可用区域内居中。
	 * 父容器须提供 flex 或 grid 的剩余空间；自然高度区域保留上下留白。
	 */
	className?: string;
	/** 可选操作入口，渲染在说明文字下方（例如「新建 Markdown / Excalidraw」）。 */
	actions?: React.ReactNode;
	children: React.ReactNode;
};

/**
 * 空态：说明「这块区域为什么是空的」，并在需要时给一个操作入口。
 *
 * 用法上先问一句「父级是不是已经有材质了」：
 * - 没有（页面级工作面）→ `variant="card"` + 铺满的尺寸类，整块区域本身就是一张卡。
 * - 有（`station-panel` / 各分栏面板 / `ScrollContainer` 内）→ `variant="plain"`。
 *
 * 全局所有「暂无数据 / 无匹配 / 尚未添加」状态都必须通过这个组件表达；
 * 由调用方根据所在表面选择 `card` 或 `plain`。加载中、请求失败等过程反馈不属于空数据状态，
 * 可以继续使用专用的反馈结构。
 */
export function EmptyCard({ icon, variant = 'card', className = '', actions, children }: Props): React.JSX.Element {
	const surface = variant === 'card' ? 'station-panel' : '';
	return (
		<div
			data-empty-state
			className={`grid min-h-0 min-w-0 flex-1 col-span-full self-stretch content-center justify-items-center gap-2 px-2 py-4 text-center ${surface} ${className}`.trim()}
		>
			<Icon name={icon} className="size-5 text-station-subtle" />
			<p className="text-xs text-station-subtle">{children}</p>
			{actions ? <div className="flex flex-wrap items-center justify-center gap-2">{actions}</div> : null}
		</div>
	);
}
