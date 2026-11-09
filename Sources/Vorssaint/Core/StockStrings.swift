// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

/// Catalog labels for every app locale. The A-share research workspace uses Chinese market terminology.
enum StockStrings {
    static func title(_ language: AppLanguage) -> String {
        switch language {
        case .enUS: return "Stock Review"
        case .ptBR: return "Revisão de operações"
        case .tr: return "Hisse işlemleri"
        case .ru: return "Дневник сделок"
        case .es: return "Revisión bursátil"
        case .sk: return "Prehľad obchodov"
        case .de: return "Handelsjournal"
        case .fr: return "Journal de trading"
        case .it: return "Diario di trading"
        case .ja: return "株式取引の振り返り"
        case .ko: return "주식 매매 복기"
        case .uk: return "Щоденник угод"
        case .zhHans: return "股票复盘"
        case .zhTW, .zhHK: return "股票復盤"
        }
    }
    static func description(_ language: AppLanguage) -> String {
        switch language {
        case .enUS: return "Record A-share and ETF trades, review positions and daily market snapshots, and keep trading plans. Chinese workspace; annual JSON files."
        case .ptBR: return "Registre operações de ações A e ETFs, posições, análises diárias e planos. Interface em chinês; arquivos JSON anuais."
        case .tr: return "A hissesi ve ETF işlemlerini, pozisyonları, günlük piyasa verilerini ve planları kaydedin. Çince arayüz; yıllık JSON dosyaları."
        case .ru: return "Сделки с акциями A и ETF, позиции, обзоры рынка и планы. Интерфейс на китайском; годовые файлы JSON."
        case .es: return "Registra operaciones de acciones A y ETF, posiciones, resúmenes diarios y planes. Interfaz en chino; archivos JSON anuales."
        case .sk: return "Zaznamenávajte obchody s akciami A a ETF, pozície, denné prehľady a plány. Čínske rozhranie; ročné súbory JSON."
        case .de: return "A-Aktien- und ETF-Trades, Positionen, tägliche Marktdaten und Handelspläne erfassen. Chinesische Oberfläche; jährliche JSON-Dateien."
        case .fr: return "Consignez les opérations sur actions A et ETF, les positions, les bilans et les plans. Interface en chinois ; fichiers JSON annuels."
        case .it: return "Registra operazioni su azioni A ed ETF, posizioni, riepiloghi giornalieri e piani. Interfaccia in cinese; file JSON annuali."
        case .ja: return "中国A株・ETFの約定、保有、日次市場データと取引計画を記録。中国語の画面、年別JSONファイル。"
        case .ko: return "중국 A주·ETF 거래, 보유 현황, 일별 시장 데이터와 계획을 기록합니다. 중국어 화면, 연도별 JSON 파일."
        case .uk: return "Угоди з акціями A та ETF, позиції, огляди ринку й плани. Інтерфейс китайською; річні файли JSON."
        case .zhHans: return "记录 A 股与 ETF 成交，查看持仓盈亏、市场快照，保存每日复盘与计划。"
        case .zhTW, .zhHK: return "記錄 A 股與 ETF 成交，查看持倉損益、市場快照，保存每日復盤與計劃。"
        }
    }
}
