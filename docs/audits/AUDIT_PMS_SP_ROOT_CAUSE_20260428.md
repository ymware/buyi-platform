# PMS双表对账根因定位（基于SP源码反编译）

**审计日期**: 2026-04-28
**对照对象**:
- SP1 = `sp_sync_mp_sales_params_sku_union` → 写 `pms_commodity_sku_params`（产品总账）
- SP2 = `sp_sync_pms_commodity_sku_wms_params_all` → 写 `pms_commodity_sku_wms_params`（mode_type×logic_warehouse 分桶）

**核心发现**: SP2 设计哲学错误——它把 SP1 总账当 truth，再用 30 天订单地理分布当权重数学拆桶，**根本没读分仓库存**。

---

## 8 处独立 BUG（按 P0/P1/P2 排序）

### P0-A 平台库存来源缺失
- **SP1 §5**: JH仓 `out_available_qty` + LX海外仓 `wid 9488/9487 product_valid_num` + FBA `available_total` 三源合计
- **SP2 §5**: 只有 FBA available_total × region_order_ratio
- 实测偏差: -18,732（platform_sale_num: 243,287 → 262,019）

### P0-B 实物库存按 ratio 数学拆分（设计错）
- **SP1 §4**: `actual_stock_qty = SUM(amf_jh_company_stock)` 物理仓直读
- **SP2 落盘**: `actual_stock_qty = cp.actual_stock_qty × region_order_ratio`
- 数学上 SUM(11桶)=总账 仅当 cp 全命中；实测 462 SKU LEFT JOIN 缺位
- 偏差: actual +26,557 / remaining +93,728

### P0-C today_sale 用 30 天权重拆当日
- `tmp_order_share` 4 个 UNION 全部 `WHERE order_date >= sub_30 AND < cur_start`（不含今日）
- 用历史 30 天权重去拆 SP1 的 today_sale_qty
- 30 天无单 SKU → tmp_share_total.all_q=NULL → 全兜底到 mode_type=2
- 偏差: today 1,689 → 100（-94%）

### P1-D 销量字段不一致

| 渠道 | SP1（总账） | SP2（权重） | 差异 |
|------|------------|------------|------|
| CG | c.order_date | c.order_date | 同 |
| JH | delivery_time + 8h | **purchase_date + 8h** | 发货 vs 下单 |
| LX_MP | FROM_UNIXTIME(global_delivery_time) | **STR_TO_DATE(global_create_time)** | 发货 vs 创建 |
| AMZ | shipment_date_local | **shipment_date_utc** | 本地 vs UTC（差 8h）|

→ 解释 656 SKU 双向 ± 偏差

### P1-E CG 店铺过滤范围不一致
- SP1 §3.1: `c.shop IN ('Target_comfort','Macy_01')` —— 2 个精确
- SP2 §3.1: `c.shop LIKE 'Target%' OR 'Macy%' OR 'BestBuy%'` —— 多匹配
- SP2 还多排 'TEMU' 平台
- → SP2 的 CG 权重池被放大 → mode=2 兜底变小 → 全部失衡

### P1-F GREATEST 兜底吃负差
- 非 FBA 五个 mode 拆销量超 truth 时，`GREATEST(truth - sum_others, 0)` 把负差吃掉
- 偏差: SUM(7d) 23,620 < truth 24,009，少 -389 全是被吃负差

### P1-G LX 海外仓库存维度错配
- SP1 §5.2 引 `amf_lx_warehouse_stock wid=9488/9487`
- SP2 §5 完全没引这张表
- → SP2 EU-OWS / CA-OWS 实物库存全靠 cp×ratio 虚构

### P2-H FBA 库存二次乘 ratio
- SP2 落盘行: `FBA → ROUND(rs.qty × region_order_ratio, 2)`
- rs.qty 已经是 SUM by (logic_wh, sku) 精准归仓
- 再乘 ratio 引入小数级舍入误差

---

## 偏差因果链拼图

| 字段 | params | SUM(wms) | 偏差 | 主因 |
|------|--------|----------|------|------|
| seven_sale_qty | 24,009 | 23,620 | -389 | P1-F + P1-D |
| thirty_sale_qty | 104,052 | 105,494 | +1,442 | P1-D + P1-E |
| today_sale_qty | 1,689 | 100 | +1,589 | P0-C + P0-B |
| actual_stock | 45,678 | 19,121 | +26,557 | P0-B |
| remaining | 145,558 | 51,830 | +93,728 | P0-B |
| open_intransit | 152,642 | 152,642 | 0 | 两边直读 shipment_item ✓ |
| platform_sale | 243,287 | 262,019 | -18,732 | P0-A + P2-H |

---

## 修复路线（按改动量排序）

### 最小改动（修 D/E/C 局部）
1. SP2 §3 销量 4 UNION 改用与 SP1 相同字段
2. SP2 §3.1 CG 过滤改 IN 精确 + 排 TEMU
3. SP2 today_sale 改"按当天订单地理直分"

### 中等改动（修 H/A 部分）
4. SP2 §5 FBA 不再二次乘 ratio
5. SP2 §5 增加 JH 仓 + LX 海外仓库存归桶到 logic_warehouse_id

### 架构级改动（修 B/G 根本）
6. **actual_stock / remaining 必须从物理仓表 SUM 实物库存按 logic_warehouse_id 直接归仓**，禁用 cp×ratio 数学拆
