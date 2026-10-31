export interface NoteTemplate {
	id: string;
	name: string;
	content: string;
}

/** 内置模板覆盖 Station 高频的项目记录场景，不引入独立模板文件系统。 */
export const noteTemplates: NoteTemplate[] = [
	{
		id: 'meeting',
		name: '会议纪要',
		content: '## 结论\n\n- [ ] \n\n## 讨论要点\n\n## 后续行动\n\n- [ ] ',
	},
	{
		id: 'decision',
		name: '项目决策',
		content: '## 背景\n\n## 备选方案\n\n## 决策\n\n> [!info] 决策结论\n> \n\n## 风险与后续\n\n- [ ] ',
	},
	{
		id: 'review',
		name: '周复盘',
		content: '## 本周完成\n\n- [ ] \n\n## 问题与复盘\n\n## 下周重点\n\n- [ ] ',
	},
	{
		id: 'study',
		name: '学习笔记',
		content: '## 核心概念\n\n## 示例\n\n## 待验证问题\n\n- [ ] \n\n## 关联笔记\n\n[[]]',
	},
];
