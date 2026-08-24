# ALVIN 定制功能迁移记录

本文记录本地版本相对于官方 KOReader 的定制功能，便于后续官方代码升级时迁移。

## 原有改动

本地版本的功能改动主要来自提交 `060d125d8`，包括：

1. **默认高亮查词结果**

   增加 `highlight_lookup_words` 设置。在 Highlight 菜单中可以控制是否在关闭词典窗口时，将当前查词选中的文本保存为 Highlight。

2. **保存词典解释到笔记**

   增加 `save_dict_lookup_to_notes` 设置。当它与 `highlight_lookup_words` 同时开启时，关闭词典窗口会把当前词典结果写入刚生成的 Highlight 笔记，格式为：

   ```text
   单词: 词典解释
   ```

   写入前会去除 HTML 标签、解码常见 HTML 实体并规范化空白字符。

3. **不弹出编辑窗口直接写笔记**

   在 Highlight 和 Bookmark 模块中增加无界面写入笔记的调用链，用于自动保存词典解释：

   - `ReaderHighlight:editNoteWithoutUI`
   - `ReaderBookmark:setBookmarkNoteWithoutUI`

   该调用会更新 annotation、同步 PDF annotation 内容、刷新相关状态并触发标注变更事件。

4. **其他历史改动**

   - `README.ALVIN.md` 曾记录本地构建、APK 签名和跳过 QuickStart 的方法。
   - 删除了一条 Highlight 调试日志。
   - 修改了两处注释文字。

   QuickStart 提交只修改了说明文档，没有修改 QuickStart 的实际代码逻辑。

## 当前迁移目标

在官方最新代码上重新实现上述 1、2、3 项功能，并作如下默认值调整：

- Highlight 默认颜色为 `gray`；
- `highlight_lookup_words` 默认开启；
- `save_dict_lookup_to_notes` 默认开启；用户可以在 Dictionary settings 中关闭自动写入词典解释。
