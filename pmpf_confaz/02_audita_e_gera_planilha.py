# -*- coding: utf-8 -*-
"""Etapa 2: audita a planilha atual contra o DOU e gera a versao atualizada.

O que faz, em ordem:
  1. monta a tabela final a partir de pmpf_dou_2026.csv + correcoes_dou.csv
     (as correcoes/retificacoes sao APLICADAS ao valor, mantendo a convencao
     que a planilha ja usava, e ficam registradas na aba 'Correcoes Aplicadas');
  2. AUDITA: compara celula por celula contra PMPF_2026_CONFAZ.xlsx nas
     vigencias que as duas versoes tem em comum e imprime toda divergencia;
  3. grava a planilha nova com as 5 abas, preservando nomes de aba e de coluna
     (main.R le a aba 'Painel PMPF 2026' e as colunas Data Vigencia / UF /
     Combustivel / Valor), e salva backup do arquivo original.

Uso: python 02_audita_e_gera_planilha.py
"""
import csv
import os
import shutil
from datetime import datetime

import openpyxl
from openpyxl.styles import Alignment, Font
from openpyxl.utils import get_column_letter

AQUI = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(AQUI)
PLANILHA = os.path.join(PROJ, "PMPF_2026_CONFAZ.xlsx")

ABA_PAINEL = "Painel PMPF 2026"
ABA_PIVOT = "AEHC por UF × Vigência"
ABA_META = "Metadados Atos"
ABA_CORR = "Correções Aplicadas"
ABA_LINKS = "Links PDFs"

# Ordem e unidade de cada combustivel, como a planilha ja registrava.
# A chave e' o nome da coluna em pmpf_dou_2026.csv.
COMBUSTIVEIS = [
    ("QAV", "QAV", "R$/litro"),
    ("AEHC", "AEHC", "R$/litro"),
    ("GNV", "GNV", "R$/m3"),
    ("GNI", "GNI", "R$/m3"),
    ("OLEO_LITRO", "OLEO_COMBUSTIVEL_LITRO", "R$/litro"),
    ("OLEO_KG", "OLEO_COMBUSTIVEL_KG", "R$/Kg"),
]

# Datas dos atos cujo PDF e' imagem (sem camada de texto), lidas no cabecalho
# do proprio DOU. Os demais saem automaticamente de atos_metadados.csv.
DATAS_ATOS_IMAGEM = {
    ("2025", "31"): ("2025-12-23", "2025-12-24"),
    ("2026", "1"): ("2026-01-08", "2026-01-09"),
    ("2026", "2"): ("2026-01-22", "2026-01-23"),
    ("2026", "3"): ("2026-01-23", "2026-01-26"),
    ("2026", "4"): ("2026-02-09", "2026-02-10"),
    ("2026", "5"): ("2026-02-24", "2026-02-25"),
    ("2026", "20"): ("2026-07-23", "2026-07-24"),
}

LINK_ESPELHO = ("https://www.revendaconectada.com.br/arqConteudo/"
                "arqAtoCotepe/Ato_Cotepe_{ano}_{n:02d}.pdf")
LINK_CONFAZ = ("https://www.confaz.fazenda.gov.br/legislacao/atos-pmpf/"
               "{ano}/pmpf{n:03d}_{aa}")


def num(txt):
    """'*5,1800' -> (5.18, '*'). '-' -> (None, '')."""
    t = (txt or "").strip()
    if t in ("", "-", "–", "—"):
        return None, ""
    marcas = ""
    while t.startswith("*"):
        marcas += "*"
        t = t[1:]
    return float(t.replace(",", ".")), marcas


def le_csv(nome):
    with open(os.path.join(AQUI, nome), encoding="utf-8") as f:
        return list(csv.DictReader(f))


def monta_painel():
    """Tabela longa final: 1 linha por vigencia x UF x combustivel informado."""
    base = le_csv("pmpf_dou_2026.csv")
    correcoes = le_csv("correcoes_dou.csv")

    # (vigencia, UF, combustivel) -> correcao
    idx_corr = {(c["vigencia_afetada"], c["UF"], c["combustivel"]): c
                for c in correcoes}
    usadas = set()

    linhas = []
    for r in base:
        for col, nome_comb, unidade in COMBUSTIVEIS:
            valor, marcas = num(r[col])
            if valor is None:
                continue  # UF nao informou PMPF desse combustivel
            corrigido_por = None
            chave = (r["vigencia"], r["UF"], nome_comb)
            if chave in idx_corr:
                c = idx_corr[chave]
                usadas.add(chave)
                valor, marcas = num(c["valor_corrigido"])
                corrigido_por = (int(c["ato_corretor"]) if c["ato_corretor"]
                                 else f"Retificação {c['fonte_dou']}")
            linhas.append({
                "vigencia": r["vigencia"],
                "ato": int(r["ato"]),
                "UF": r["UF"],
                "combustivel": nome_comb,
                "valor": valor,
                "unidade": unidade,
                "alterado": "Sim" if marcas else None,
                "reducao": "Sim" if marcas == "**" else None,
                "corrigido_por": corrigido_por,
            })

    faltando = set(idx_corr) - usadas
    if faltando:
        raise SystemExit(f"correcoes sem linha-base correspondente: {faltando}")

    ordem = {nome: i for i, (_, nome, _) in enumerate(COMBUSTIVEIS)}
    linhas.sort(key=lambda x: (x["vigencia"], x["UF"], ordem[x["combustivel"]]))
    return linhas, correcoes


def audita(linhas):
    """Compara com a planilha atual nas vigencias em comum."""
    if not os.path.exists(PLANILHA):
        print("planilha atual nao encontrada; auditoria ignorada")
        return
    wb = openpyxl.load_workbook(PLANILHA, data_only=True)
    ws = wb[ABA_PAINEL]
    antigo = {}
    for r in ws.iter_rows(min_row=2, values_only=True):
        if not r[3] or r[0] is None:
            continue  # linha de nota
        antigo[(str(r[0])[:10], r[2], r[3])] = r
    novo = {(x["vigencia"], x["UF"], x["combustivel"]): x for x in linhas}

    vigs_antigas = {k[0] for k in antigo}
    vigs_novas = {k[0] for k in novo}
    comuns = vigs_antigas & vigs_novas

    print(f"\n{'='*72}\nAUDITORIA vs {os.path.basename(PLANILHA)}")
    print(f"{'='*72}")
    print(f"celulas: planilha atual={len(antigo)}  nova={len(novo)}")
    print(f"vigencias: atual={len(vigs_antigas)}  nova={len(vigs_novas)}  "
          f"em comum={len(comuns)}")
    print(f"vigencias NOVAS: {sorted(vigs_novas - vigs_antigas)}")
    if vigs_antigas - vigs_novas:
        print(f"vigencias PERDIDAS (erro!): {sorted(vigs_antigas - vigs_novas)}")

    difs = []
    for k in sorted(set(antigo) & set(novo)):
        if k[0] not in comuns:
            continue
        a, n = antigo[k], novo[k]
        if abs((a[4] or 0) - n["valor"]) > 1e-9:
            difs.append(("valor", k, a[4], n["valor"]))
        if (a[1] or None) != n["ato"]:
            difs.append(("ato_base", k, a[1], n["ato"]))
        if (a[6] or None) != n["alterado"]:
            difs.append(("alterado", k, a[6], n["alterado"]))
        if (a[7] or None) != n["reducao"]:
            difs.append(("reducao", k, a[7], n["reducao"]))
        if (a[5] or None) != n["unidade"]:
            difs.append(("unidade", k, a[5], n["unidade"]))

    só_antigo = [k for k in antigo if k[0] in comuns and k not in novo]
    só_novo = [k for k in novo if k[0] in comuns and k not in antigo]

    print(f"\ncelulas nas vigencias em comum -> divergencias: {len(difs)}")
    for campo, k, va, vn in difs:
        print(f"   {k[0]} {k[1]:<3} {k[2]:<24} {campo:<9} "
              f"atual={va!r:<12} DOU={vn!r}")
    print(f"celulas presentes so na planilha atual: {len(só_antigo)}")
    for k in só_antigo:
        print(f"   {k}")
    print(f"celulas presentes so na versao nova:     {len(só_novo)}")
    for k in só_novo:
        print(f"   {k}")
    return difs


def monta_metadados(linhas, correcoes):
    meta_pdf = {m["ato"]: m for m in le_csv("atos_metadados.csv") if m["ato"]}
    vig_por_ato = {}
    for x in linhas:
        vig_por_ato.setdefault(str(x["ato"]), x["vigencia"])

    corr_por_ato = {}
    for c in correcoes:
        if c["ato_corretor"]:
            corr_por_ato.setdefault(c["ato_corretor"], c)

    atos = sorted({str(x["ato"]) for x in linhas} | set(corr_por_ato),
                  key=lambda a: (0 if a == "31" else 1, int(a)))
    saida = []
    for a in atos:
        ano = "2025" if a == "31" else "2026"
        datas = DATAS_ATOS_IMAGEM.get((ano, a))
        if datas:
            data_ato, data_dou = datas
        else:
            m = meta_pdf.get(a, {})
            data_ato, data_dou = m.get("data_ato", ""), m.get("data_dou", "")
        c = corr_por_ato.get(a)
        tipo = "correcao" if c else "base"
        saida.append({
            "ato": int(a),
            "ano": int(ano),
            "data_ato": data_ato or "—",
            "data_dou": data_dou or "—",
            "tipo": tipo,
            "ato_corrigido": int(c["ato_corrigido"]) if c else "—",
            "item_uf": (f"{int(c['item']):02d}-{c['UF']}" if c else "—"),
            "vigencia": vig_por_ato.get(a, "—"),
            "status": "tabela completa recuperada" if not c else
                      "correcao recuperada",
        })
    # A retificacao do Ato 5 nao tem numero de ato proprio: fica como nota.
    return saida


def escreve(linhas, correcoes, metadados):
    wb = openpyxl.Workbook()
    negrito = Font(bold=True)

    def cabecalho(ws, nomes, larguras):
        ws.append(nomes)
        for c in ws[1]:
            c.font = negrito
            c.alignment = Alignment(vertical="center")
        for i, w in enumerate(larguras, start=1):
            ws.column_dimensions[get_column_letter(i)].width = w
        ws.freeze_panes = "A2"

    # --- aba 1: painel longo (a que o main.R le) ---
    ws = wb.active
    ws.title = ABA_PAINEL
    cabecalho(ws, ["Data Vigência", "Ato Base", "UF", "Combustível",
                   "Valor", "Unidade", "Alterado (*)", "Redução (**)",
                   "Corrigido por Ato"],
              [14, 9, 6, 24, 10, 10, 12, 13, 30])
    for x in linhas:
        # Data Vigencia gravada como TEXTO ISO, igual a versao anterior da
        # planilha, para nao mudar o que o read_excel()/as.Date() do main.R ve.
        ws.append([x["vigencia"], x["ato"], x["UF"], x["combustivel"],
                   x["valor"], x["unidade"], x["alterado"], x["reducao"],
                   x["corrigido_por"]])
    for row in ws.iter_rows(min_row=2, min_col=5, max_col=5):
        row[0].number_format = "0.0000"

    ws.append([])
    for nota in [
        "Notas:",
        "* Valores alterados de PMPF em relação ao período anterior (Ato base).",
        "** Valores alterados que apresentam redução em relação ao período anterior.",
        "Uma UF só aparece com o combustível que informou naquela quinzena; "
        "'-' no DOU = sem PMPF informada (linha ausente aqui).",
        "Valores de Atos de correção/retificação JÁ ESTÃO APLICADOS na coluna "
        "Valor; a coluna 'Corrigido por Ato' e a aba 'Correções Aplicadas' "
        "guardam o valor original.",
        "Vigência 2026-01-01 vem do Ato COTEPE/PMPF 31/2025 (DOU 24/12/2025) — "
        "e' a PMPF em vigor na 1ª quinzena de janeiro/2026.",
        "Fonte: PDFs dos Atos COTEPE/PMPF no DOU (espelho revendaconectada.com.br). "
        "NÃO use a versão HTML do confaz.fazenda.gov.br: na conferência de "
        "17/09/2026 ela devolveu valores errados (Ato 7: AC/AM/AP) e, no Ato 5, "
        "embutiu a retificação no corpo da tabela.",
        "Reconstruído por pmpf_confaz/02_audita_e_gera_planilha.py em "
        + datetime.now().strftime("%d/%m/%Y"),
    ]:
        ws.append([nota])

    # --- aba 2: AEHC por UF x vigencia (leitura humana) ---
    ws2 = wb.create_sheet(ABA_PIVOT)
    vigs = sorted({x["vigencia"] for x in linhas})
    ufs = sorted({x["UF"] for x in linhas})
    aehc = {(x["vigencia"], x["UF"]): x["valor"]
            for x in linhas if x["combustivel"] == "AEHC"}
    cabecalho(ws2, ["UF \\ Vigência"] + vigs, [14] + [11] * len(vigs))
    for uf in ufs:
        ws2.append([uf] + [aehc.get((v, uf), "—") for v in vigs])
    for row in ws2.iter_rows(min_row=2, min_col=2):
        for c in row:
            if isinstance(c.value, float):
                c.number_format = "0.0000"
    ws2.append([])
    for nota in [
        "Combustível: AEHC – Álcool Etílico Hidratado Combustível (R$/litro).",
        "'—' = UF não informou PMPF de AEHC nessa quinzena.",
        "Série completa: todas as 15 vigências de 01/01/2026 a 01/08/2026 "
        "estão presentes (nenhum ato pendente).",
        "PE em 2026-03-01 = 5,1800 já com a retificação do DOU de 05/03/2026 "
        "(publicado originalmente como 4,9200).",
    ]:
        ws2.append([nota])

    # --- aba 3: metadados dos atos ---
    ws3 = wb.create_sheet(ABA_META)
    cabecalho(ws3, ["Nº Ato", "Ano", "Data do Ato", "Data DOU", "Tipo",
                    "Ato Corrigido", "Item/UF Corrigido", "Vigência",
                    "Status Dados"],
              [8, 7, 13, 12, 10, 14, 18, 13, 28])
    for m in metadados:
        ws3.append([m["ato"], m["ano"], m["data_ato"], m["data_dou"], m["tipo"],
                    m["ato_corrigido"], m["item_uf"], m["vigencia"],
                    m["status"]])
    ws3.append([])
    ws3.append(["Todos os atos de 01/01/2026 a 01/08/2026 foram recuperados "
                "do PDF do DOU."])
    ws3.append(["Além destes, há uma RETIFICAÇÃO do Ato 5/2026 publicada no DOU "
                "de 05/03/2026 (item 16-PE), sem número de ato próprio — "
                "ver aba 'Correções Aplicadas'."])

    # --- aba 4: correcoes aplicadas ---
    ws4 = wb.create_sheet(ABA_CORR)
    cabecalho(ws4, ["Vigência Afetada", "Ato Corretor", "Ato Corrigido",
                    "Tipo", "Item", "UF", "Combustível", "Valor Anterior",
                    "Valor Corrigido", "Fonte DOU"],
              [16, 13, 14, 13, 7, 6, 12, 14, 15, 40])
    for c in correcoes:
        va, _ = num(c["valor_anterior"])
        vc, _ = num(c["valor_corrigido"])
        ws4.append([c["vigencia_afetada"],
                    int(c["ato_corretor"]) if c["ato_corretor"] else "—",
                    int(c["ato_corrigido"]), c["tipo"], int(c["item"]),
                    c["UF"], c["combustivel"], va, vc, c["fonte_dou"]])
    for row in ws4.iter_rows(min_row=2, min_col=8, max_col=9):
        for c in row:
            if isinstance(c.value, float):
                c.number_format = "0.0000"
    ws4.append([])
    ws4.append(["'Valor Anterior' = valor como saiu no ato-base original; "
                "'Valor Corrigido' = valor válido, que e' o gravado na aba "
                "'Painel PMPF 2026'."])

    # --- aba 5: links dos PDFs ---
    ws5 = wb.create_sheet(ABA_LINKS)
    cabecalho(ws5, ["Nº Ato", "Ano", "Tipo", "Vigência", "Status",
                    "PDF do DOU (espelho Revenda Conectada)",
                    "Página no confaz.fazenda.gov.br"],
              [8, 7, 10, 13, 28, 72, 68])
    for m in metadados:
        n, ano = m["ato"], m["ano"]
        ws5.append([n, ano, m["tipo"], m["vigencia"], m["status"],
                    LINK_ESPELHO.format(ano=ano, n=n),
                    LINK_CONFAZ.format(ano=ano, n=n, aa=str(ano)[2:])])
    ws5.append([])
    for nota in [
        "O PDF do espelho e' cópia fiel do DOU e e' a fonte usada aqui.",
        "A página HTML do CONFAZ serve para localizar o ato, mas NÃO para "
        "copiar valores: na conferência de 17/09/2026 ela trouxe números "
        "divergentes do DOU.",
        "PDFs dos Atos 31/2025 e 1, 2, 3, 4, 5 e 20/2026 são imagem "
        "(sem texto): foram transcritos à mão em "
        "pmpf_confaz/transcricoes_dou.csv.",
    ]:
        ws5.append([nota])

    if os.path.exists(PLANILHA):
        backup = os.path.join(
            PROJ, "PMPF_2026_CONFAZ_backup_"
            + datetime.now().strftime("%Y%m%d_%H%M%S") + ".xlsx")
        shutil.copy2(PLANILHA, backup)
        print(f"\nbackup do original -> {os.path.basename(backup)}")
    wb.save(PLANILHA)
    print(f"planilha gravada  -> {os.path.basename(PLANILHA)}")
    print(f"  {ABA_PAINEL}: {len(linhas)} linhas de dados, "
          f"{len(vigs)} vigencias")


def main():
    linhas, correcoes = monta_painel()
    audita(linhas)
    metadados = monta_metadados(linhas, correcoes)
    escreve(linhas, correcoes, metadados)


if __name__ == "__main__":
    main()
