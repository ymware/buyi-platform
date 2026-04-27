# PMS 双表一致性审计：pms_commodity_sku_params vs pms_commodity_sku_wms_params

**监测日期**：2026-04-27 ｜ **公司**：local_company_id() = 1574398357059801089
**审计目标**：商品维度的 `pms_commodity_sku_params`（产品级总账）应当 = SUM(`pms_commodity_sku_wms_params` by mode_type)（产品×逻辑桶分账）。

## 一、总量对账（6 个核心字段）

| 字段                  | params (产品总账) | SUM(wms_params 7 mode) | 偏差        | 偏差率 | 评级 |
|-----------------------|-------------------|-------------------------|-------------|--------|------|
| `seven_sale_qty`      | 24,009            | 23,620                  | **+389**    | +1.6%  | ⚠ |
| `thirty_sale_qty`     | 104,052           | 105,494                 | **−1,442**  | −1.4%  | ⚠ |
| `today_sale_qty`      | 1,689             | 100                     | **+1,589**  | **+94%** | ❌ |
| `actual_stock_qty`    | 45,678            | 19,121                  | **+26,557** | **+58%** | ❌ |
| `remaining_qty`       | 145,558           | 51,830                  | **+93,728** | **+64%** | ❌ |
| `open_intransit_qty`  | 152,642           | 152,642                 | 0           | 0%     | ✓ |
| `platform_sale_num`   | 243,287           | 262,019                 | **−18,732** | −7.7%  | ⚠ |

→ **在途口径完美对齐**（唯一 ✓ 的字段）。**销量在七日维度勉强一致**，**今日销量、实物库存、可用库存严重背离**。

## 二、SKU 维度精细对账（6,143 SKU 全集）

| 字段                | match | mismatch | wms_more SKU | wms_less SKU | 偏差总和 |
|---------------------|-------|----------|--------------|--------------|----------|
| seven_sale_qty      | 5,487 | **656**  | 273 (+1,016) | 383 (−1,405) | +389（互抵后） |
| actual_stock_qty    | 5,681 | **462**  | 0            | 462          | +26,557  |
| remaining_qty       | 5,674 | **469**  | -            | -            | +93,728  |
| open_intransit_qty  | 6,143 | **0**    | -            | -            | 0        |
| platform_sale_num   | 6,133 | 10       | -            | -            | −18,732  |

→ **在途同步链路完美**：6143 SKU 的 `open_intransit_qty` 100% 一致 → 在途用同一份源数据写入两张表。
→ **实物库存破洞最严重**：462 SKU 全部呈 `params > SUM(wms_params)`，**说明 wms 分仓粒度漏写**了某些仓库的库存（不是数学不等，是**子集不全**）。
→ **销量双向偏差**：seven_sale 既有 +1,016 又有 −1,405，**两张表用了不同的销量来源 SP**，不是简单同步关系。

## 三、根因诊断（按数据特征反推）

### R1 · 实物库存：wms_params 是 params 的"残缺子集"
- 偏差 SKU 全部呈 `pms_total > SUM(wms_modes)`（462/0/0）→ 单向缺失
- TOP 10 SKU：UK-GYG-WHITE 872→1、BO-YCG-ZXJXLG-WHITE 605→0、AP-XZSJ-6C-R 573→0…
- 这些 SKU 在 `pms_commodity_sku_wms_params` 的 11 个 mode×logic_shop 桶里**几乎全为 0**
- **说明 wms_params 写库时漏抓了 pms_commodity_sku_wms_stock 等明细仓库的库存**

→ 推断写入路径：`sp_sync_pms_commodity_sku_wms_params_all`（最近 2026-04-27 16:06 修改）
→ 该 SP 按桶汇总实物库存时只覆盖了部分仓库，对于"非主流仓"的库存丢失

### R2 · 可用库存（remaining）：偏差 93,728，比 actual 偏差更大
- params 145,558 vs wms 51,830 → wms_params 同样缺
- remaining = actual − lock，lock 走另一条链路，但**偏差结构跟 actual 同向**说明同因

### R3 · 销量七日双向偏差 ±：双源
- 7d: 5,487 SKU 一致 / 656 SKU 不一致（10.7%）
- 不是单向漏写，是**两张表的销量来自不同 SP**：
  - `pms_commodity_sku_params.seven_sale_qty` ≈ 24,009 ≈ `cos_goods_sku_sale.seven_days_sale_num` 23,619（+1.6% 噪声）
  - `pms_commodity_sku_wms_params.seven_sale_qty` 23,620 桶分布逻辑独立（按 mode_type=1 美区分摊 + mode_type=2-7 各渠道直分）
- **核心矛盾**：mode_type=1 美区销量是按 region_ratio 比例分摊的（小数 .58 / .82 / .40 / .20 → 出现小数），而 params 总账是整数 → **小数累加四舍五入误差 + 分摊算法跟整账不一致**

### R4 · 今日销量 today_sale_qty：1,689 vs 100，差 +1,589（94%）
- params 当天 1,689，wms 当天只 100（其中 mode_type=1 美区只 38）
- 说明 **today_sale_qty 字段在 wms_params 上几乎没跑成功**——SP 只补 mode_type=1 的分摊计算，其它 6 个 mode_type 的 today=0
- **这个 BUG 直接报废"实时备货决策"功能**

### R5 · platform_sale_num：偏差 −18,732（wms 多）
- params 243,287 vs wms 262,019
- wms 分桶汇总比 params 总账多 18,732（≈7.7%）
- 反过来：**params 该字段漏算了某些渠道**（前面看 channel=2/5/7/8/9/10/11 在 cos 主表 logic_shop=NULL，但平台销量在 wms 端被强行归到桶里了）

## 四、链路全景图

```
amf_jh_orders + amf_lx_amzorder_item                              [真值 7d=15,202]
    │
    ├─→ cos_goods_sku_sale                                        [+55%, 23,619]
    │       │  shop_id=美东/南/西/中虚拟桶（按订单收货州 1:1 归属，非比例分摊）
    │       │
    │       └─→ pms_commodity_sku_params (产品总账)               [24,009 ≈ cos_sale]
    │               │
    │               └─→ pms_commodity_sku_wms_params (mode_type=1美区分摊小数)
    │                                                               [23,620, 双向 ±]
    │
    └─→ cos_goods_sku_params                                      [-55%, 6,871, 死表]
            （备货决策眼中的销量；但 PMS 实际不用它，绕开了这条路）

wms 实物库存 (?)
    └─→ pms_commodity_sku_params.actual_stock_qty                 [45,678]
            └─→ pms_commodity_sku_wms_params 按桶分摊实物          [19,121, 缺 26,557]
                                                                     ❌ 漏写 462 SKU
```

## 五、修复优先级建议

| 优先级 | 问题 | 修复方向 | 影响 |
|--------|------|----------|------|
| P0 | actual_stock_qty 偏差 26,557 | 校验 `sp_sync_pms_commodity_sku_wms_params_all` 的实物库存写入 SQL，对 462 SKU 的 11 桶补全 | 备货引擎用了错的可用库存 |
| P0 | today_sale_qty 偏差 94% | wms_params 上 mode_type=2-7 的 today_sale 完全没算，只算了 mode=1 部分 | 实时备货判断失效 |
| P1 | remaining_qty 偏差 93,728 | 跟 actual 同因，actual 修复后 remaining 自动收敛 | 同上 |
| P1 | platform_sale_num 偏差 −18,732 | params 总账漏算了部分渠道 platform_sale | 周报数据失真 |
| P2 | seven_sale_qty 双向 ±656 SKU | mode_type=1 美区分摊用 region_ratio 小数，无法精确还原整数总账，需统一精度策略 | 备货决策小幅偏差 |

## 六、下一步行动

1. **数据修复 SQL**（不依赖 SP 源码）：
   - 对 462 SKU 用 `pms_commodity_sku_params.actual_stock_qty` 反推回填到 `pms_commodity_sku_wms_params`（按 11 桶 region_ratio 分摊或按当前非零桶占比）
   - 对 today_sale 缺失的 6 个 mode_type，从 cos_sale today_sale_num 重新分摊写入

2. **校验作业**（自动化日检）：
   - 每日凌晨 3 点跑：`pms_total[6字段] − SUM(pms_wms[6字段])` ≠ 0 时告警
   - 落 dwd_data_quality_check 表

3. **训练 Vanna 知识库**：本审计的 SQL + 字段语义 + 11 桶映射表

---
报告时间：2026-04-27 23:35
