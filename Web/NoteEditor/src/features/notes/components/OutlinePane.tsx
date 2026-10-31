import { useMemo, useState } from 'react';
import type { MarkdownHeading } from '@/markdown';
import { Icon } from '@/shared/components/Icon';
import { SearchInput } from '@/shared/components/SearchInput';
import { ScrollContainer } from '@/shared/components/ScrollContainer';
import { EmptyCard } from '@/shared/components/EmptyCard';
import { Tooltip } from '@/shared/components/Tooltip';

type Props = { headings: MarkdownHeading[]; onSelectHeading: (offset: number) => void };
type OutlineNode = MarkdownHeading & { children: OutlineNode[] };

function buildOutlineTree(headings: MarkdownHeading[]): OutlineNode[] {
	// 通过栈维护最近的父标题，将 Markdown 标题转换为嵌套目录树。
	const roots: OutlineNode[] = [];
	const stack: OutlineNode[] = [];
	for (const heading of headings) {
		const node: OutlineNode = { ...heading, children: [] };
		while (stack.length && stack[stack.length - 1].level >= heading.level) stack.pop();
		if (stack.length) stack[stack.length - 1].children.push(node);
		else roots.push(node);
		stack.push(node);
	}
	return roots;
}

export function OutlinePane({ headings, onSelectHeading }: Props): React.JSX.Element {
	const [searchOpen, setSearchOpen] = useState(false);
	const [searchText, setSearchText] = useState('');
	const [activeOffset, setActiveOffset] = useState<number | null>(null);
	const [collapsed, setCollapsed] = useState<Set<number>>(new Set());
	const outlineTree = useMemo(() => buildOutlineTree(headings), [headings]);
	const searchResults = useMemo(() => {
		const keyword = searchText.trim().toLocaleLowerCase();
		return keyword ? headings.filter((heading) => heading.text.toLocaleLowerCase().includes(keyword)) : null;
	}, [headings, searchText]);
	const collapsible = headings.filter((heading, index) => headings[index + 1]?.level > heading.level).map((heading) => heading.offset);
	const allCollapsed = collapsible.length > 0 && collapsible.every((offset) => collapsed.has(offset));
	function toggle(offset: number): void {
		// Set 保证折叠状态按标题偏移去重，且不会修改原集合。
		setCollapsed((current) => {
			const next = new Set(current);
			if (next.has(offset)) next.delete(offset);
			else next.add(offset);
			return next;
		});
	}
	function toggleAll(): void {
		// 根据当前是否全部收起，在所有可折叠节点和空集合之间切换。
		setCollapsed(allCollapsed ? new Set() : new Set(collapsible));
	}
	function select(offset: number): void {
		// 先更新目录选中态，再通知正文滚动到对应标题。
		setActiveOffset(offset);
		onSelectHeading(offset);
	}
	function renderNode(node: OutlineNode): React.JSX.Element {
		// 每个节点只负责自身标题和子树，子列表容器承担层级竖线。
		const hasChildren = node.children.length > 0;
		return (
			<li key={node.offset} className="flex min-w-0 flex-col">
				<div
					className="note-outline-item flex min-w-0 items-center gap-1 text-xs text-station-muted"
					data-selected={activeOffset === node.offset || undefined}
				>
					<button
						type="button"
						aria-label={collapsed.has(node.offset) ? '展开子标题' : '收起子标题'}
						aria-expanded={hasChildren ? !collapsed.has(node.offset) : undefined}
						className={`grid size-4 shrink-0 place-items-center rounded-md text-station-subtle hover:bg-white/10 ${hasChildren ? '' : 'invisible'}`}
						onClick={() => toggle(node.offset)}
					>
						{hasChildren && (
							<Icon name="chevron-down" className={`size-3 transition-transform ${collapsed.has(node.offset) ? '-rotate-90' : ''}`} />
						)}
					</button>
					<button
						type="button"
						className="min-w-0 flex-1 truncate text-left text-station-text hover:text-station-text"
						onClick={() => select(node.offset)}
					>
						{node.text}
					</button>
				</div>
				{hasChildren && !collapsed.has(node.offset) && (
					<ul className="note-outline-children ml-2 flex flex-col pl-2">{node.children.map(renderNode)}</ul>
				)}
			</li>
		);
	}
	return (
		<section className="select-none flex min-h-0 flex-1 flex-col gap-2">
			{/* 头部只剩两个图标按钮：直接作为 header 的子项右对齐，不再多包一层 div。 */}
			<header className="flex shrink-0 items-center justify-end">
				<Tooltip content="搜索目录">
					<button
						type="button"
						className="station-icon-button size-6"
						aria-label="搜索目录"
						onClick={() => setSearchOpen((value) => !value)}
					>
						<Icon name="search" className="size-3.5" />
					</button>
				</Tooltip>
				<Tooltip content={allCollapsed ? '展开目录' : '收起目录'}>
					<button
						type="button"
						className="station-icon-button size-6"
						aria-label={allCollapsed ? '展开目录' : '收起目录'}
						disabled={!collapsible.length}
						onClick={toggleAll}
					>
						<Icon name={allCollapsed ? 'expand-all' : 'collapse-all'} className="size-3.5 text-station-subtle" />
					</button>
				</Tooltip>
			</header>
			{searchOpen && <SearchInput value={searchText} onChange={setSearchText} placeholder="搜索标题" autoFocus className="shrink-0" />}
			{headings.length ? (
				<ScrollContainer as="ul" layout="none" className="flex-1">
					{searchResults ? searchResults.map((heading) => renderNode({ ...heading, children: [] })) : outlineTree.map(renderNode)}
					{searchResults && !searchResults.length && (
						<li className="flex min-h-0 flex-1 flex-col">
							<EmptyCard variant="plain" icon="search">
								没有匹配的标题
							</EmptyCard>
						</li>
					)}
				</ScrollContainer>
			) : (
				<EmptyCard variant="plain" icon="notes" className="flex-1">
					正文中暂无 Markdown 标题
				</EmptyCard>
			)}
		</section>
	);
}
