# AMF → COS 销量主链路一致性审计报告
监测日期：2026-04-27 ｜ 公司：local_company_id() = 1574398357059801089

## 终极三向对账（核心结论）

| 口径                         | 7 日累计 | 备注 |
|------------------------------|----------|------|
| AMF 真值（订单 quantity_ordered）| **15,202** | 领星亚马逊 8,925 + 鲸汇全平台 6,277 |
| cos_goods_sku_sale.7d        | **23,619** | **多算 +8,417 (+55.4%)** ❌ |
| cos_goods_sku_params.7d      | **6,871**  | **少算 −8,331 (−54.8%)** ❌ |

→ 同一 ERP 数据源出来的两个核心销量表，相对真值分别 +55% 和 −55% 的偏差，**两个 SP 跑出来的销量根本对不上 AMF 真值，更对不上彼此**。

## P0-A · cos_goods_sku 主表 logic_shop_id 映射严重残缺

| channel_type | 渠道           | SKU 数 | logic_shop_id 归桶          |
|--------------|----------------|--------|------------------------------|
| 3            | 亚马逊         | 9,876  | ✓ US-FBA 7067 / CA-FBA 2039 / EU-FBA 770 |
| 14           | CG（沃尔玛批发?）| 3,197  | ✓ 全部 → CG (1764655782335020009) |
| 2            | TEMU           | 2,555  | ✗ 全 NULL |
| 5            | TikTok         | 6,829  | ✗ 全 NULL |
| 7            | 鲸汇OEM        | 2,181  | ✗ 全 NULL |
| 8            | 深圳力天/MJJ批发| 3,835  | ✗ 全 NULL |
| 9            | Walmart 多店   | 5,099  | ✗ 全 NULL |
| 10           | OVERSTOCK/loviy| 2,420  | ✗ 全 NULL |
| 11           | homyshop/eBay  | 3,894  | ✗ 全 NULL |
| **合计 NULL**|                | **26,813** | **66.6% 的 SKU 没有 logic_shop_id** |
| 合计已归桶   |                | 13,103 |  |

**12 个业务逻辑桶里有 7 个完全空仓**：美东 / 美南 / 美西 / 美中 / 美北 / EU-OWS / CA-OWS。
→ 涉及 `sp_sync_cos_goods_spu_sku_from_multi_source`（2026-04-19 最近修改），**只实现了亚马逊 channel=3 + CG channel=14 的 logic_shop_id 落地**，其它 9 个非 FBA 渠道未实现。

## P0-B · cos_goods_sku_params 7 日销量短缺 8,331

`sp_sync_cos_goods_sku_params_daily`（2026-04-21 修改）只对**亚马逊 SKU**写入 logic_shop_id 和 seven_sale_qty：
- params 表 31,781 SKU 中只有 4,968 SKU 落桶（US/EU/CA-FBA），其它 26,813 SKU `logic_shop_id IS NULL`、销量也大概率为 0
- 该表被 PMS/WMS 备货引擎吃，**直接导致非亚马逊 SKU 的备货决策销量为 0** → 无法触发补货 → 链路终端缺货风险

## P0-C · cos_goods_sku_sale 销量 +55% 虚高

| 表象 | 实际 |
|------|------|
| sale 7 日 = 23,619 | AMF 7 日 = 15,202 |

**SP 不是按 region_ratio 切分**，而是按 SKU 真实订单收货地址 100% 归一个区域：
- 14,283 SKU 全部 `region_count = 1`（一个 SKU 只在 美东/美南/美西/美中 4 个虚拟桶之一出现）
- 4 桶分布：美西 36,478 / 美东 36,157 / 美南 23,843 / 美中 12,980

**多算 8,417 的可能根因**（待源码确认）：
1. 同 ERP 一笔订单两个数据源（领星 lx + 鲸汇 jh）双面入账
2. 退款/取消的订单未扣减
3. 历史订单回填窗口与 AMF 当日切片差异

## P0-D · sale ↔ params SKU 集合不一致

```
params SKU = 31,781 ←→ sale SKU = 14,283
交集     = 12,298（仅 38.7% params SKU 在 sale 表里）
仅 params= 19,483（含 NULL-桶 SKU 上千）
仅 sale  = 1,985（sale 有销量但主表/params 找不到的 "孤儿"）
```

→ sale 与 params 跑的 SKU 全集都不一样。两条 SP 链路独立各自维护，**没有一致性约束**。

## P0-E · today 维度全死

`today_sale_num=1` 仅 72 条。说明 SP 只跑昨天结算后的"已闭单"订单，**当天实时单全部丢失**。如果运营看实时仪表盘会全是 0。

## SP 元数据线索

| SP                                              | 最近修改       | 嫌疑 |
|-------------------------------------------------|---------------|------|
| `sp_sync_cos_goods_sku_params_daily`            | 2026-04-21    | P0-B 主嫌 |
| `sp_sync_cos_goods_spu_sku_from_multi_source`   | 2026-04-19    | P0-A 主嫌 |
| `sp_batch_update_step2_sales`                   | 2026-04-14    | P0-C 嫌疑 |
| `sp_batch_update_step4_cos`                     | 2026-04-14    | P0-C 嫌疑 |
| `sp_sync_mp_sales_params_sku_union`             | 2026-04-24    | sale 主嫌 |
| `sp_sync_pms_commodity_sku_wms_params_all`      | 2026-04-27 16:06 | 今天动过，PMS 链路最新 |
| `sp_sync_pms_commodity_shipment_all`            | 2026-04-27 14:49 | 今天动过 |

⚠ SP body 在 RDS 上**通过 SHOW CREATE 和 mysql.proc 都不可读**（current_user 无 SHOW_ROUTINE 权限、mysql.proc 也被 deny）。
→ 必须走运维通道（DBA console / 控制台 / 主从备份 dump）才能拿源码进一步定位修复点。

## 已修复部分（前轮）

- `cos_shop_group_relation`：软删 68 条孤儿（备份 `_bak_..._20260427`）
- `wms_warehouse_group_relation`：23 条 type=2 美区关系修复，11 个业务逻辑仓全对齐 `amf_warehouse_region` 真值
- 11 个业务逻辑桶（type=2）现状：FBA/CA-FBA/EU-FBA/CG/EU-OWS/4 美区/美北 ✓，CA-OWS=0（无 type=3 country=CA 实仓）

## 下一步建议（按优先级）

1. **P0-A 修复（必须）**：在 `sp_sync_cos_goods_spu_sku_from_multi_source` 内补齐 channel ∈ {2,5,7,8,9,10,11} 的 logic_shop_id 归桶规则。**需要业务确认非 FBA 渠道→桶的映射**：
   - TikTok/Walmart/OVERSTOCK/eBay 等海外仓发货 → 默认 EU-OWS / 美西（按目的国 country_code）
   - 鲸汇 OEM/批发 → CG ?
2. **P0-B 修复**：params SP 同步上修，**所有有销量 SKU 必须有 logic_shop_id**
3. **P0-C 排查**：sale 7d=23619 vs AMF=15202 多 55% → dump SP 源码定位重复入账
4. 建立 SP 落库后的**自动一致性校验作业**（每日 cron）：amf 真值 ↔ sale ↔ params 三向 ±5% 告警
5. 当 SP 源码到手 → 训练 Vanna 知识库

---
报告时间：2026-04-27 23:18
