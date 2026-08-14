"""指示書生成ヘルパー。

使い方:
    python3 genbrief.py <出力先ディレクトリ> <tag1> [<tag2> ...]

<出力先ディレクトリ>/next_pair.json に briefs.json のエントリを
tag の数だけ配列で置いてから呼ぶ。各エントリから
<出力先ディレクトリ>/wt21-<tag>.txt を生成する。

briefs.json と brief_template.txt はこのファイルと同じディレクトリ
（.claude/port-briefs/）にある想定。
"""
import sys, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
tmpl = open(os.path.join(HERE, 'brief_template.txt')).read()


def gen(x, tag, out):
    files = '\n'.join(
        '- `' + f.replace('/Users/yoshinori/work/nimculus/', '') + '`'
        for f in x['files_to_touch']
    )
    b = f"""Zed の移植です。ワークトリー `nimculus-wt-{tag}` で作業しています。
cd /Users/yoshinori/work/nimculus-wt-{tag} で作業すること。

## このタスクが所有するファイル
{files}

## {x['mechanism']}

Zed: `{x['zed_reference']}`

### 現状との差
{x['what_is_missing']}

### 受け入れ条件
{x['acceptance']}

### 確認方法
{x.get('verifiable_by', '')}

{tmpl}"""
    open(out, 'w').write(b)
    return len(b)


if __name__ == '__main__':
    outdir = sys.argv[1]
    tags = sys.argv[2:]
    pair = json.load(open(os.path.join(outdir, 'next_pair.json')))
    for x, tag in zip(pair, tags):
        n = gen(x, tag, os.path.join(outdir, f'wt21-{tag}.txt'))
        print(tag, n, 'chars')
