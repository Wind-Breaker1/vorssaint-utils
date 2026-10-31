import type {NoteDetail, NotePropertyType} from '../../contracts';
export type Stored = {
    id: string;
    title: string;
    body: string;
    type?: 'markdown' | 'excalidraw';
    tags: string[];
    properties: {
        id: string;
        name: string;
        kind: string;
        value: string;
    }[];
};
const kinds: Record<NotePropertyType, string> = { text: '文本', number: '数字', checkbox: '复选框', date: '日期', list: '列表' };
export function decode(data: Stored): NoteDetail { return { id: data.id, title: data.title, content: data.body, tags: data.tags ?? [], type: data.type ?? 'markdown', properties: (data.properties ?? []).map(p => { const type = (Object.keys(kinds) as NotePropertyType[]).find(t => kinds[t] === p.kind) ?? 'text'; let value: any = p.value; if (type === 'checkbox')
        value = p.value === 'true'; if (type === 'number')
        value = Number(p.value); if (type === 'list') {
        try {
            value = JSON.parse(p.value);
            if (!Array.isArray(value))
                throw Error();
        }
        catch {
            value = p.value.split(',').filter(Boolean);
        }
    } return { id: p.id, key: p.name, type, value }; }) }; }
export function encode(note: NoteDetail): Stored { return { id: note.id, title: note.title, body: note.content, type: note.type, tags: note.tags, properties: note.properties.map(p => ({ id: p.id ?? (p.id = crypto.randomUUID()), name: p.key, kind: kinds[p.type], value: Array.isArray(p.value) ? JSON.stringify(p.value) : String(p.value) })) }; }
