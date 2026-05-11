# MK 项目工作约定

## Git 流程

本项目是单人开发的个人仓（GuinsooRocky/mk），**无 PR review 流程**。

### 例外：允许同步 feature 分支到 remote main

`git push origin <feature-branch>:main`

**触发场景**：feature 分支开发完毕后，把 main 同步到 feature HEAD。

**为什么放行**：
- 单人项目，没有协作者需要 PR review 保护
- main 不是产线分支，是"展示当前最新可用版本"的别名
- 全局 memory rule "never push to main/master/release/develop" 仍对**其他多人项目**生效

### 仍需谨慎

- `git push --force` 到 main：仍要明确确认
- 删除 main 分支：仍要明确确认
- 修改远程 default branch：仍要明确确认
