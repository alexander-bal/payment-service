# Products

## Overview

Products are the goods offered for sale in the app catalog. A product carries identity (name, SKU, URL slug), classification (category, tags), pricing in a single currency (with an optional compare-at price for promotions), physical attributes, and a lifecycle status that decides whether customers can see it. The catalog is exposed both as a management API for other services and tools, and as a customer-facing storefront: a paginated grid of active products and a detail page addressed by slug.

## Goals and Non-Goals

### Goals

- Define the product entity and its observable field contract
- Define the three-status lifecycle and which statuses are customer-visible
- Define the management surface: create, read by id and by slug, update, delete, list with filtering and pagination
- Define the storefront catalog and product detail surfaces, including their empty, loading, and not-found states
- Define the uniqueness, precision, and validation limits the catalog enforces

### Non-Goals

- Inventory management — stock levels, warehouses, stock movements
- Product variants (size, color, material) and product bundles or kits
- Media galleries — a product carries at most one image reference
- Product reviews and ratings
- Soft delete and audit history for products
- Bulk import and export

## Functional Requirements

### FR-1: Product Identity

- A product SHALL carry a system-generated identifier, a `name`, a globally unique `sku`, a globally unique URL-friendly `slug`, a `currency`, and a `price`.
- The system SHALL generate the `slug` from the product name at creation time.
- A product MAY carry a `description`, a `shortDescription`, a `category`, `tags`, an `imageUrl`, a `compareAtPrice`, a `costPrice`, and the physical attributes `weight`, `width`, `height`, and `length`.
- A product SHALL carry `createdAt` and `updatedAt` timestamps, both system-assigned.

### FR-2: Product Lifecycle

- A product SHALL carry a `status` of `draft`, `active`, or `archived` (LIM-3).
- A newly created product SHALL default to `draft`.
- Only an `active` product SHALL be visible on the storefront (FR-7, FR-8, LIM-6); `draft` and `archived` products SHALL be reachable only through the management surface.
- Archiving SHALL remove a product from the storefront while retaining it in the system.

### FR-3: Product Creation

- The system SHALL accept product creation via `POST /api/products`.
- Creation SHALL require `name`, `sku`, `price`, and `currency`; every other field SHALL be optional.
- Creation SHALL assign the identifier, slug, timestamps, and default status, and SHALL return the complete product including those generated values.
- Creation SHALL be rejected when the supplied `sku` or the generated `slug` collides with an existing product (LIM-1).

### FR-4: Product Retrieval

- The system SHALL expose `GET /api/products/:id` and `GET /api/products/by-slug/:slug`, each returning the complete product.
- Both retrieval paths SHALL reach a product in any status; storefront visibility is a property of the surface (FR-7, FR-8), not of retrieval.

### FR-5: Product Update

- The system SHALL accept partial updates via `PATCH /api/products/:id`; a field absent from the request SHALL retain its current value.
- An update SHALL validate supplied fields before persisting and SHALL refresh `updatedAt`.
- An update SHALL return the complete product with all current values.

### FR-6: Product Deletion and Listing

- The system SHALL accept `DELETE /api/products/:id` as a permanent removal, returning a success acknowledgement carrying the deleted product's identifier.
- The system SHALL expose `GET /api/products`, filterable by `status` and by `category` (both exact match), ordered by creation date with the newest first.
- Listing SHALL be paginated (LIM-2) and the response SHALL carry the total count of matching products alongside the current page, page size, and total page count.

### FR-7: Storefront Catalog

- The storefront catalog SHALL be addressed at `/products`.
- The storefront catalog SHALL display only `active` products, paginated, in a responsive grid of equal-size cards.
- Each card SHALL display the product's name, price, image, and short description, and SHALL navigate to that product's detail page when activated.
- A product with no image SHALL display a generic placeholder image in its place.
- A product with a `compareAtPrice` SHALL display that price struck through alongside the current price.
- A card SHALL truncate the product name and short description with an ellipsis rather than overflow its bounds.
- The catalog SHALL display a loading indicator while products are being retrieved, and an empty-state message when no active product exists.
- The catalog SHALL display pagination controls below the grid when more than one page of results exists, and SHALL make the current page number and total page count visible.

### FR-8: Product Detail Surface

- The product detail surface SHALL be addressed by product slug at `/products/:slug` and SHALL resolve the product by that slug.
- The surface SHALL display the product image (or the placeholder), name, untruncated description, price with the struck-through compare-at price where present, and the category and tags where present.
- The surface SHALL display a loading indicator while the product is being retrieved and an error state when no product matches the slug.
- The surface SHALL offer a back control that returns the customer to the previously viewed page.

## Technical Requirements (System Limits)

These are binding limits on observable behavior, each verifiable from outside. The parenthetical notes point to where each is realized.

- **LIM-1 — Unique SKU and slug.** No two products share a `sku`, and no two share a `slug`; a create or update that would collide is rejected as a conflict. (FR-3, FR-5)
- **LIM-2 — Page size bounds.** Catalog page size is an integer in the range 1–100 inclusive, defaulting to 20; the page number starts at 1 and defaults to 1. A value outside those bounds is rejected. (FR-6, FR-7)
- **LIM-3 — Closed status vocabulary.** A product's `status` is one of `draft`, `active`, `archived`; any other value is rejected. (FR-2)
- **LIM-4 — Monetary and measurement precision.** `price`, `compareAtPrice`, `costPrice`, `weight`, `width`, `height`, and `length` each carry exactly two decimal places. Weight is expressed in grams and the three dimensions in centimeters. (FR-1)
- **LIM-5 — Required fields.** A product always has a `name`, `sku`, `slug`, `currency`, and `price`; none of them may be cleared by an update. (FR-1, FR-3, FR-5)
- **LIM-6 — Storefront visibility.** No `draft` or `archived` product appears on any storefront surface, in any listing, at any page. (FR-2, FR-7)
- **LIM-7 — Cost price is not public.** `costPrice` is never rendered on a storefront surface. (Security)

## Constraints (Externally Imposed)

- **CON-1 — ISO 4217 currency codes.** A product's `currency` is an ISO 4217 code; the vocabulary is defined by that standard, not by this feature. (FR-1)
- **CON-2 — Line-item snapshots.** Carts and orders capture a product's name, SKU, image, and price at the moment an item is added and do not track later product edits; those snapshot semantics are owned by `cart.md` and `orders.md`. (FR-5)
- **CON-3 — Search ownership.** Keyword matching, ranking, and the search surface are owned by `product-search.md`; this feature owns only the fields search reads and the `active`-only visibility rule it honors. (FR-7, LIM-6)

## Error Scenarios

| Scenario | Response |
|---|---|
| Create or update a product with a missing required field or an invalid value | HTTP 400 — validation error |
| Create a product with a `sku` already in use, or whose generated `slug` collides | HTTP 409 — conflict |
| Retrieve, update, or delete a product that does not exist | HTTP 404 — product not found |
| List products with a page size outside 1–100, or a page number below 1 | HTTP 400 — validation error |
| Request a `status` outside `draft` / `active` / `archived` | HTTP 400 — validation error |
| Open a detail surface for a slug that matches no product | Error state on the surface; no product data rendered |
| Render a product that carries no image | The generic placeholder image is displayed in its place |
| Unexpected failure on any product route | HTTP 500 — internal server error |

## Security Considerations

- `costPrice` SHALL be withheld from every storefront surface, so the catalog does not disclose acquisition cost or margin to customers (LIM-7).
- `draft` and `archived` products SHALL be unreachable from the storefront, so unreleased and withdrawn products are not exposed ahead of or beyond their intended availability (LIM-6).
- Product input SHALL be validated at the API boundary before persistence, so malformed values never reach storage (FR-3, FR-5).
