# PMS SP 修复 patch 升级版（v2.0 / 2026-04-28）

> 本报告基于 user 提供的 4 张权威真值视图 (`v_amf_warehouse_stock` / `v_amf_jh_lx_order` / `v_amf_onhand_stock` / `v_amf_onroad_stock`) 重新核对 SP1/SP2，并落地三层归桶修复方案。

## 1. 视图 vs SP 对照（销量字段口径）

| 渠道  | 视图字段                              | SP1                          | SP2                              | 谁对齐   |
|-------|---------------------------------------|------------------------------|----------------------------------|----------|
| JH    | `delivery_time + 8h`                  | `delivery_time + 8h` ✓       | `purchase_date + 8h` ✗           | **SP1**  |
| LX_MP | `from_unixtime(global_delivery_time)` | 同 ✓                         | `STR_TO_DATE(global_create_time)` ✗ | **SP1** |
| AMZ   | `shipment_date_local`                 | 同 ✓                         | `shipment_date_utc` ✗            | **SP1**  |
| CG    | `LIKE Target%/Macy%/BestBuy% + 排除TEMU` | `IN ('Target_comfort','Macy_01')` ✗ | 同 ✓                  | **SP2**  |

**重大修正**：CG 维度 SP2 才对齐视图，SP1 漏抓 BestBuy 整批店铺。

## 2. 桶映射基础数据空洞（重大发现）

`wms_warehouse_group(group_wms_type=2)` 11 个业务桶：MD/MN/MX/MZ/MB/FBA/EU-FBA/CA-FBA/CG/EU-OWS/CA-OWS

`cos_shop_group(group_type=2)` 与上一致，11 行 100% 桥接 ✓

但 `cos_shop_group_relation` 对 group_type=2 的覆盖严重不全：

| 维度                            | 覆盖桶数 |
|---------------------------------|----------|
| ✓ 店铺挂载到桶（5/11）          | FBA(26) 美西(25) 加FBA(10) 欧FBA(9) 美南(0实际有但未入表) |
| ❌ 完全空（6/11）               | 美东 / 美南 / 美中 / 美北 / CG / 欧OWS / 加OWS |
| ✓ 物理仓挂载到桶（10/11）       | CA-FBA(20) FBA(42) EU-FBA(9) MD(4) MN(6) MX(9) MZ(4) CG(2) EU-OWS(2) |
| ❌ 物理仓空                     | CA-OWS / MB |

**含义**：SP2 当前用 `country_code` 硬编码归桶 **并非懒惰，而是被迫 workaround**——基础数据 `cos_shop_group_relation` 提供不了 "shop → 美东/美西/CG" 的归属。

## 3. 修复方案（终版三层归桶）

任意订单/库存归桶按优先级解析：

1. **店铺归桶**：`shop_id → cos_shop_group_relation → cos_shop_group(group_type=2).id = wms_warehouse_group.logic_shop_id`
2. **仓库归桶**：`warehouse_id → wms_warehouse_group_relation → wms_warehouse_group(group_wms_type=2)`
3. **兜底**：`country_code → 11 桶`（消除 SP2 当前唯一硬编码 BUG，但仍保底）

## 4. 8 处 BUG 修复对照

| BUG 编号 | 字段                  | 偏差        | 修复点              |
|----------|------------------------|-------------|---------------------|
| P0-A     | platform_sale_num      | -18,732     | §1 三源 UNION       |
| P0-B     | actual_stock/remaining | +26K/+93K   | §2 物理仓直归桶     |
| P0-C     | today_sale             | +1,589      | §3 今日订单直分桶   |
| P1-D     | sale 字段              | -389/+1,442 | §4 改用视图字段     |
| P1-E     | CG 店铺                | -           | §4 视图自动 LIKE    |
| P1-F     | GREATEST 兜底          | -389        | §4 不再用兜底       |
| P1-G     | LX 海外仓              | -           | §1 视图含 wid 9488/9487 |
| P2-H     | FBA × ratio            | 小          | §5 取消二次乘       |

## 5. 项目侧建议

1. 先补 `cos_shop_group_relation` 美东/美南/美中/美北/CG/OWS 6 桶的店铺成员
2. 维护 `amf_warehouse_map`（或类似映射表）：AMF 仓库代码 → wms_warehouse.id
3. 跑修复版 SP 后用 `v_amf_jh_lx_order` 校验偏差应 <1%

## 6. 文件清单

- [`sql/v_amf_truth_views.sql`](sql/v_amf_truth_views.sql) — 4 视图 DDL（用户 2026-04-28 提供）
- [`sql/sp_sync_pms_commodity_sku_wms_params_all.fixed.sql`](sql/sp_sync_pms_commodity_sku_wms_params_all.fixed.sql) — SP2 修复 patch v2.0
- [`AUDIT_PMS_SP_ROOT_CAUSE_20260428.md`](AUDIT_PMS_SP_ROOT_CAUSE_20260428.md) — 8 BUG 根因分析（v1，已被本报告升级）
