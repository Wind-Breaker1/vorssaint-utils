export function toast(message:string,_options?:unknown){window.dispatchEvent(new CustomEvent('note-toast',{detail:message}))}
