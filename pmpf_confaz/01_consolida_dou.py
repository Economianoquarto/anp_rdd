# -*- coding: utf-8 -*-
"""Etapa 1: consolida as tabelas dos Atos COTEPE/PMPF em um unico CSV verbatim.

Duas origens, porque os PDFs do DOU vem em dois formatos:

  (a) PDFs COM camada de texto (Atos 6, 7, 9, 12, 13, 14, 17, 18, 19 e as
      alteracoes 8, 10, 11, 15, 16, 21) -> extraidos por script com pdfplumber.
  (b) PDFs SEM camada de texto, so imagem (Ato 31/2025 e Atos 1, 2, 3, 4, 5,
      20 de 2026) -> transcritos a mao em `transcricoes_dou.csv`.

Por que NAO usamos as paginas HTML do confaz.fazenda.gov.br: na auditoria de
17/09/2026 elas devolveram valores ERRADOS. No Ato 7 a pagina mostrou
AC 5,2254 / AM 5,4413 / AP 5,7900 quando o DOU traz 5,3984 / 5,5409 / 5,8900;
e no Ato 5 mostrou PE 5,1800 embutindo a retificacao no corpo da tabela, em vez
do valor originalmente publicado (4,9200). O PDF do DOU e' a fonte confiavel.

Entrada : transcricoes_dou.csv
          PDFs em <dir_pdf> (default: ./pdf_dou), baixados por 00_baixa_pdfs.py
Saida   : pmpf_dou_2026.csv  (1 linha por vigencia x UF, valores verbatim)
          atos_metadados.csv (1 linha por ato)

Uso: python 01_consolida_dou.py [dir_pdf]
"""
import csv
import glob
import os
import re
import sys
import unicodedata

import pdfplumber

AQUI = os.path.dirname(os.path.abspath(__file__))
DIR_PDF = sys.argv[1] if len(sys.argv) > 1 else os.path.join(AQUI, "pdf_dou")

COLS = ["QAV", "AEHC", "GNV", "GNI", "OLEO_LITRO", "OLEO_KG"]
UFS = ["AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO", "MA", "MG", "MS",
       "MT", "PA", "PB", "PE", "PI", "PR", "RJ", "RN", "RO", "RR", "RS", "SC",
       "SE", "SP", "TO"]
MESES = {"janeiro": 1, "fevereiro": 2, "marco": 3, "abril": 4, "maio": 5,
         "junho": 6, "julho": 7, "agosto": 8, "setembro": 9, "outubro": 10,
         "novembro": 11, "dezembro": 12}

# Uma celula da tabela: "-" (UF nao informou) ou ate 2 asteriscos + numero
# com virgula decimal. Os asteriscos sao as notas do DOU:
#   *  valor alterado de PMPF;  ** valor alterado que apresenta reducao.
TOKEN = re.compile(r"^(?:\*{0,2}\d{1,3},\d{3,4}|[-–—])$")


def sem_acento(s):
    return "".join(c for c in unicodedata.normalize("NFD", s)
                   if unicodedata.category(c) != "Mn")


def data_extenso(texto, padrao):
    m = re.search(padrao, sem_acento(texto), re.I)
    if not m:
        return ""
    dia, mes, ano = int(m.group(1)), m.group(2).lower(), int(m.group(3))
    return f"{ano:04d}-{MESES[mes]:02d}-{dia:02d}" if mes in MESES else ""


def le_pdf(caminho):
    """Le um PDF do DOU e devolve (metadados, linhas verbatim).

    Devolve linhas=[] quando o PDF nao tem camada de texto (e' imagem); nesse
    caso a tabela vem de transcricoes_dou.csv.
    """
    with pdfplumber.open(caminho) as pdf:
        texto = "\n".join((p.extract_text() or "") for p in pdf.pages)
    t = sem_acento(texto)

    m_num = re.search(r"ATO COTEPE/PMPF N[º°o]?\s*(\d+)", t, re.I)
    m_dou = re.search(r"Publicado em:\s*(\d{2})/(\d{2})/(\d{4})", texto)
    m_cor = re.search(r"Ato COTEPE/PMPF n[º°o]?\s*(\d+), de", texto)

    meta = {
        "ato": m_num.group(1) if m_num else "",
        "data_ato": data_extenso(
            texto, r"N[º°o]?\s*\d+,\s*DE\s*(\d{1,2})\s*DE\s*(\w+)\s*DE\s*(\d{4})"),
        "data_dou": (f"{m_dou.group(3)}-{m_dou.group(2)}-{m_dou.group(1)}"
                     if m_dou else ""),
        "vigencia": data_extenso(
            texto, r"a partir d[eo]\s*(?:dia\s*)?(\d{1,2})[º°o]?\s*de\s*(\w+)\s*de\s*(\d{4})"),
        "tem_texto": "sim" if texto.strip() else "nao",
        "arquivo": os.path.basename(caminho),
    }

    linhas = []
    for linha in texto.split("\n"):
        m = re.match(r"\s*(\d{1,2})\s+([A-Z]{2})\s+(.+)$", linha)
        if not m or m.group(2) not in UFS:
            continue
        tokens = m.group(3).split()
        # Toda linha da tabela do DOU tem exatamente 6 colunas de combustivel.
        # Se nao tiver, prefiro falhar alto a gravar dado torto.
        if len(tokens) != 6 or not all(TOKEN.match(tk) for tk in tokens):
            raise ValueError(
                f"{meta['arquivo']}: linha nao reconhecida -> {linha!r}")
        linhas.append({"item": int(m.group(1)), "UF": m.group(2),
                       **dict(zip(COLS, tokens))})
    return meta, linhas


def main():
    transcricoes = {}
    with open(os.path.join(AQUI, "transcricoes_dou.csv"), encoding="utf-8") as f:
        for r in csv.DictReader(f):
            transcricoes.setdefault(r["vigencia"], []).append(r)

    metadados, consolidado = [], []
    vistos = set()

    for caminho in sorted(glob.glob(os.path.join(DIR_PDF, "*.pdf"))):
        meta, linhas = le_pdf(caminho)
        metadados.append(meta)
        if not linhas or len(linhas) < 27:
            continue  # imagem, ou ato de alteracao (1 linha) -> correcoes_dou.csv
        vig = meta["vigencia"]
        if not vig or vig in vistos:
            continue
        vistos.add(vig)
        for r in linhas:
            consolidado.append({
                "vigencia": vig, "ato": meta["ato"], "ano_ato": vig[:4],
                "item": r["item"], "UF": r["UF"],
                **{c: r[c] for c in COLS},
                "origem": "pdf_texto", "fonte_dou": f"DOU {meta['data_dou']}",
            })

    for vig, linhas in transcricoes.items():
        if vig in vistos:
            print(f"  aviso: vigencia {vig} veio do PDF com texto; "
                  f"transcricao ignorada")
            continue
        vistos.add(vig)
        for r in linhas:
            consolidado.append({
                "vigencia": vig, "ato": r["ato"], "ano_ato": r["ano_ato"],
                "item": int(r["item"]), "UF": r["UF"],
                **{c: r[c] for c in COLS},
                "origem": "transcricao_imagem", "fonte_dou": r["fonte_dou"],
            })

    consolidado.sort(key=lambda r: (r["vigencia"], r["item"]))

    campos = (["vigencia", "ato", "ano_ato", "item", "UF"] + COLS
              + ["origem", "fonte_dou"])
    saida = os.path.join(AQUI, "pmpf_dou_2026.csv")
    with open(saida, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=campos)
        w.writeheader()
        w.writerows(consolidado)

    with open(os.path.join(AQUI, "atos_metadados.csv"), "w",
              encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["ato", "data_ato", "data_dou",
                                          "vigencia", "tem_texto", "arquivo"])
        w.writeheader()
        w.writerows(sorted(metadados, key=lambda m: int(m["ato"] or 0)))

    vigs = sorted({r["vigencia"] for r in consolidado})
    print(f"{len(consolidado)} linhas, {len(vigs)} vigencias -> {saida}")
    for v in vigs:
        bloco = [r for r in consolidado if r["vigencia"] == v]
        print(f"   {v}  ato {bloco[0]['ato']:>2}  UFs={len(bloco)}  "
              f"{bloco[0]['origem']}")


if __name__ == "__main__":
    main()
