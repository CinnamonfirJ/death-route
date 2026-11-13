//! Camp Commodities: the NEP-245 multi-token contract behind the Dead Route camp market.
//!
//! One contract, many token ids. Token "1" is a Medkit, "2" Premium Ammo, "3" a Pizza Delivery
//! Contract, and so on (see economy/pricing_rules.toml). Every courier wallet and every merchant
//! NPC wallet holds balances of these ids.
//!
//! Two layers of API:
//!   * NEP-245 core + metadata + events, so wallets and explorers understand the tokens.
//!   * A relayer layer for the game backend: `mt_mint` when a courier banks a haul, and
//!     `relayed_transfer(intent_id, ...)` which executes a player's trade intent idempotently.
//!     Players never sign; the backend is an approved operator and pays the gas.
use near_sdk::json_types::U128;
use near_sdk::serde_json::json;
use near_sdk::store::{IterableMap, IterableSet, LookupMap, LookupSet};
use near_sdk::{
    assert_one_yocto, env, ext_contract, log, near, require, AccountId, BorshStorageKey, Gas,
    PanicOnDefault, PromiseError, PromiseOrValue,
};

pub type TokenId = String;

const GAS_FOR_ON_TRANSFER: Gas = Gas::from_tgas(35);
const GAS_FOR_RESOLVE: Gas = Gas::from_tgas(10);
const MAX_BATCH: usize = 32;

#[near(serializers = [borsh])]
#[derive(BorshStorageKey)]
enum StorageKey {
    Operators,
    Tokens,
    Supply,
    Balances,
    Intents,
}

/// NEP-245 contract-level metadata.
#[near(serializers = [json, borsh])]
#[derive(Clone, Debug, PartialEq)]
pub struct MtContractMetadata {
    pub spec: String,
    pub name: String,
    pub symbol: String,
    pub icon: Option<String>,
    pub base_uri: Option<String>,
    pub reference: Option<String>,
    pub reference_hash: Option<String>,
}

/// NEP-245 base metadata shared by every unit of a token id.
#[near(serializers = [json, borsh])]
#[derive(Clone, Debug, PartialEq)]
pub struct MtBaseTokenMetadata {
    pub name: String,
    pub id: String,
    pub symbol: Option<String>,
    pub icon: Option<String>,
    pub decimals: Option<String>,
    pub base_uri: Option<String>,
    pub reference: Option<String>,
    pub copies: Option<u64>,
    pub reference_hash: Option<String>,
}

/// NEP-245 per-token metadata.
#[near(serializers = [json, borsh])]
#[derive(Clone, Debug, PartialEq, Default)]
pub struct MtTokenMetadata {
    pub title: Option<String>,
    pub description: Option<String>,
    pub media: Option<String>,
    pub media_hash: Option<String>,
    pub issued_at: Option<String>,
    pub expires_at: Option<String>,
    pub starts_at: Option<String>,
    pub updated_at: Option<String>,
    pub extra: Option<String>,
    pub reference: Option<String>,
    pub reference_hash: Option<String>,
}

#[near(serializers = [json, borsh])]
#[derive(Clone, Debug, PartialEq)]
pub struct TokenInfo {
    pub base: MtBaseTokenMetadata,
    pub token: MtTokenMetadata,
}

#[near(serializers = [json])]
#[derive(Clone, Debug, PartialEq)]
pub struct Token {
    pub token_id: TokenId,
    /// Fungible token ids have no single owner.
    pub owner_id: Option<AccountId>,
}

#[near(serializers = [json])]
#[derive(Clone, Debug, PartialEq)]
pub struct MtTokenMetadataAll {
    pub base: MtBaseTokenMetadata,
    pub token: MtTokenMetadata,
}

pub type Approval = (AccountId, u64);

#[ext_contract(ext_mt_receiver)]
pub trait MultiTokenReceiver {
    /// Returns the amounts the receiver did NOT use, which are refunded to the sender.
    fn mt_on_transfer(
        &mut self,
        sender_id: AccountId,
        previous_owner_ids: Vec<AccountId>,
        token_ids: Vec<TokenId>,
        amounts: Vec<U128>,
        msg: String,
    ) -> PromiseOrValue<Vec<U128>>;
}

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct CampCommodities {
    owner_id: AccountId,
    /// Accounts allowed to mint, burn and execute relayed intents (the game backend).
    operators: IterableSet<AccountId>,
    tokens: IterableMap<TokenId, TokenInfo>,
    supply: LookupMap<TokenId, u128>,
    /// "<token_id>|<account_id>" -> balance.
    balances: LookupMap<String, u128>,
    /// Intent ids already executed. Retrying one is a no-op, never a double spend.
    intents: LookupSet<String>,
    metadata: MtContractMetadata,
}

fn balance_key(token_id: &str, account_id: &AccountId) -> String {
    format!("{token_id}|{account_id}")
}

fn emit(event: &str, data: near_sdk::serde_json::Value) {
    log!(
        "EVENT_JSON:{}",
        json!({ "standard": "nep245", "version": "1.0.0", "event": event, "data": [data] })
    );
}

#[near]
impl CampCommodities {
    #[init]
    pub fn new(owner_id: AccountId, name: Option<String>, symbol: Option<String>) -> Self {
        let mut operators = IterableSet::new(StorageKey::Operators);
        operators.insert(owner_id.clone());
        Self {
            owner_id,
            operators,
            tokens: IterableMap::new(StorageKey::Tokens),
            supply: LookupMap::new(StorageKey::Supply),
            balances: LookupMap::new(StorageKey::Balances),
            intents: LookupSet::new(StorageKey::Intents),
            metadata: MtContractMetadata {
                spec: "mt-1.0.0".to_string(),
                name: name.unwrap_or_else(|| "Dead Route Camp Commodities".to_string()),
                symbol: symbol.unwrap_or_else(|| "CAMP".to_string()),
                icon: None,
                base_uri: None,
                reference: None,
                reference_hash: None,
            },
        }
    }

    // ------------------------------------------------------------------ admin / relayer

    fn assert_owner(&self) {
        require!(env::predecessor_account_id() == self.owner_id, "Owner only");
    }

    fn assert_operator(&self) {
        require!(self.operators.contains(&env::predecessor_account_id()), "Operator only");
    }

    pub fn owner(&self) -> AccountId {
        self.owner_id.clone()
    }

    pub fn add_operator(&mut self, account_id: AccountId) {
        self.assert_owner();
        self.operators.insert(account_id);
    }

    pub fn remove_operator(&mut self, account_id: AccountId) {
        self.assert_owner();
        require!(account_id != self.owner_id, "The owner stays an operator");
        self.operators.remove(&account_id);
    }

    pub fn is_operator(&self, account_id: AccountId) -> bool {
        self.operators.contains(&account_id)
    }

    /// Declares a token id. Re-registering an existing id updates its metadata.
    pub fn register_token(
        &mut self,
        token_id: TokenId,
        base: MtBaseTokenMetadata,
        token: Option<MtTokenMetadata>,
    ) {
        self.assert_operator();
        require!(!token_id.is_empty() && token_id.len() <= 64, "Invalid token id");
        require!(!token_id.contains('|'), "Token id cannot contain '|'");
        let info = TokenInfo { base, token: token.unwrap_or_default() };
        if !self.supply.contains_key(&token_id) {
            self.supply.insert(token_id.clone(), 0);
        }
        self.tokens.insert(token_id, info);
    }

    /// Courier banked a haul: mint commodities into their wallet. Operator only.
    pub fn mt_mint(
        &mut self,
        receiver_id: AccountId,
        token_id: TokenId,
        amount: U128,
        memo: Option<String>,
    ) {
        self.assert_operator();
        self.assert_token(&token_id);
        require!(amount.0 > 0, "Amount must be positive");
        let supply = self.supply.get(&token_id).copied().unwrap_or(0);
        self.supply.insert(token_id.clone(), supply.checked_add(amount.0).expect("Supply overflow"));
        let balance = self.internal_balance(&token_id, &receiver_id);
        self.internal_set_balance(&token_id, &receiver_id, balance + amount.0);
        emit(
            "mt_mint",
            json!({ "owner_id": receiver_id, "token_ids": [token_id], "amounts": [amount.0.to_string()], "memo": memo }),
        );
    }

    /// Dispatch redeemed a contract, a medkit was consumed: burn. Operator only.
    pub fn mt_burn(
        &mut self,
        owner_id: AccountId,
        token_id: TokenId,
        amount: U128,
        memo: Option<String>,
    ) {
        self.assert_operator();
        self.assert_token(&token_id);
        require!(amount.0 > 0, "Amount must be positive");
        let balance = self.internal_balance(&token_id, &owner_id);
        require!(balance >= amount.0, "Insufficient balance to burn");
        self.internal_set_balance(&token_id, &owner_id, balance - amount.0);
        let supply = self.supply.get(&token_id).copied().unwrap_or(0);
        self.supply.insert(token_id.clone(), supply - amount.0);
        emit(
            "mt_burn",
            json!({ "owner_id": owner_id, "authorized_id": env::predecessor_account_id(),
                "token_ids": [token_id], "amounts": [amount.0.to_string()], "memo": memo }),
        );
    }

    /// Executes a courier's trade intent on their behalf. The backend matched the intent
    /// (price, merchant, quantity) off-chain; this moves the tokens. Idempotent per intent id:
    /// a retry after a timeout returns `false` and changes nothing.
    pub fn relayed_transfer(
        &mut self,
        intent_id: String,
        sender_id: AccountId,
        receiver_id: AccountId,
        token_ids: Vec<TokenId>,
        amounts: Vec<U128>,
        memo: Option<String>,
    ) -> bool {
        self.assert_operator();
        require!(!intent_id.is_empty() && intent_id.len() <= 128, "Invalid intent id");
        if self.intents.contains(&intent_id) {
            return false;
        }
        self.intents.insert(intent_id.clone());
        let memo = Some(match memo {
            Some(m) => format!("intent:{intent_id} {m}"),
            None => format!("intent:{intent_id}"),
        });
        self.internal_transfer(&sender_id, &receiver_id, &token_ids, &amounts, memo);
        true
    }

    pub fn intent_executed(&self, intent_id: String) -> bool {
        self.intents.contains(&intent_id)
    }

    // ------------------------------------------------------------------ NEP-245 core

    #[payable]
    pub fn mt_transfer(
        &mut self,
        receiver_id: AccountId,
        token_id: TokenId,
        amount: U128,
        approval: Option<Approval>,
        memo: Option<String>,
    ) {
        assert_one_yocto();
        require!(approval.is_none(), "Approvals are not supported");
        let sender_id = env::predecessor_account_id();
        self.internal_transfer(&sender_id, &receiver_id, &[token_id], &[amount], memo);
    }

    #[payable]
    pub fn mt_batch_transfer(
        &mut self,
        receiver_id: AccountId,
        token_ids: Vec<TokenId>,
        amounts: Vec<U128>,
        approvals: Option<Vec<Option<Approval>>>,
        memo: Option<String>,
    ) {
        assert_one_yocto();
        require!(
            approvals.map_or(true, |a| a.iter().all(Option::is_none)),
            "Approvals are not supported"
        );
        let sender_id = env::predecessor_account_id();
        self.internal_transfer(&sender_id, &receiver_id, &token_ids, &amounts, memo);
    }

    #[payable]
    pub fn mt_transfer_call(
        &mut self,
        receiver_id: AccountId,
        token_id: TokenId,
        amount: U128,
        approval: Option<Approval>,
        memo: Option<String>,
        msg: String,
    ) -> PromiseOrValue<Vec<U128>> {
        require!(approval.is_none(), "Approvals are not supported");
        self.mt_batch_transfer_call(receiver_id, vec![token_id], vec![amount], None, memo, msg)
    }

    #[payable]
    pub fn mt_batch_transfer_call(
        &mut self,
        receiver_id: AccountId,
        token_ids: Vec<TokenId>,
        amounts: Vec<U128>,
        approvals: Option<Vec<Option<Approval>>>,
        memo: Option<String>,
        msg: String,
    ) -> PromiseOrValue<Vec<U128>> {
        assert_one_yocto();
        require!(
            approvals.map_or(true, |a| a.iter().all(Option::is_none)),
            "Approvals are not supported"
        );
        require!(
            env::prepaid_gas() >= GAS_FOR_ON_TRANSFER.saturating_add(GAS_FOR_RESOLVE).saturating_add(Gas::from_tgas(5)),
            "More gas is required"
        );
        let sender_id = env::predecessor_account_id();
        self.internal_transfer(&sender_id, &receiver_id, &token_ids, &amounts, memo);
        let previous_owner_ids = vec![sender_id.clone(); token_ids.len()];
        ext_mt_receiver::ext(receiver_id.clone())
            .with_static_gas(GAS_FOR_ON_TRANSFER)
            .mt_on_transfer(sender_id, previous_owner_ids.clone(), token_ids.clone(), amounts.clone(), msg)
            .then(
                Self::ext(env::current_account_id())
                    .with_static_gas(GAS_FOR_RESOLVE)
                    .mt_resolve_transfer(previous_owner_ids, receiver_id, token_ids, amounts),
            )
            .into()
    }

    /// Refunds whatever the receiver reported as unused (or everything if it panicked).
    /// Returns the amounts the receiver kept.
    #[private]
    pub fn mt_resolve_transfer(
        &mut self,
        previous_owner_ids: Vec<AccountId>,
        receiver_id: AccountId,
        token_ids: Vec<TokenId>,
        amounts: Vec<U128>,
        #[callback_result] unused: Result<Vec<U128>, PromiseError>,
    ) -> Vec<U128> {
        let unused: Vec<u128> = match unused {
            Ok(values) if values.len() == amounts.len() => values.iter().map(|v| v.0).collect(),
            _ => amounts.iter().map(|a| a.0).collect(),
        };
        let mut used = Vec::with_capacity(amounts.len());
        for (i, token_id) in token_ids.iter().enumerate() {
            let sent = amounts[i].0;
            let mut refund = unused[i].min(sent);
            if refund > 0 {
                let receiver_balance = self.internal_balance(token_id, &receiver_id);
                refund = refund.min(receiver_balance);
                if refund > 0 {
                    self.internal_set_balance(token_id, &receiver_id, receiver_balance - refund);
                    let owner = &previous_owner_ids[i];
                    let owner_balance = self.internal_balance(token_id, owner);
                    self.internal_set_balance(token_id, owner, owner_balance + refund);
                    emit(
                        "mt_transfer",
                        json!({ "old_owner_id": receiver_id, "new_owner_id": owner,
                            "token_ids": [token_id], "amounts": [refund.to_string()], "memo": "refund" }),
                    );
                }
            }
            used.push(U128(sent - refund));
        }
        used
    }

    pub fn mt_token(&self, token_ids: Vec<TokenId>) -> Vec<Option<Token>> {
        token_ids
            .into_iter()
            .map(|id| self.tokens.contains_key(&id).then(|| Token { token_id: id, owner_id: None }))
            .collect()
    }

    pub fn mt_balance_of(&self, account_id: AccountId, token_id: TokenId) -> U128 {
        U128(self.internal_balance(&token_id, &account_id))
    }

    pub fn mt_batch_balance_of(&self, account_id: AccountId, token_ids: Vec<TokenId>) -> Vec<U128> {
        token_ids.iter().map(|id| U128(self.internal_balance(id, &account_id))).collect()
    }

    pub fn mt_supply(&self, token_id: TokenId) -> Option<U128> {
        self.supply.get(&token_id).map(|s| U128(*s))
    }

    pub fn mt_batch_supply(&self, token_ids: Vec<TokenId>) -> Vec<Option<U128>> {
        token_ids.iter().map(|id| self.supply.get(id).map(|s| U128(*s))).collect()
    }

    // ------------------------------------------------------------------ NEP-245 metadata

    pub fn mt_metadata_contract(&self) -> MtContractMetadata {
        self.metadata.clone()
    }

    pub fn mt_metadata_token_all(&self, token_ids: Vec<TokenId>) -> Vec<Option<MtTokenMetadataAll>> {
        token_ids
            .iter()
            .map(|id| {
                self.tokens.get(id).map(|t| MtTokenMetadataAll { base: t.base.clone(), token: t.token.clone() })
            })
            .collect()
    }

    pub fn mt_metadata_token_by_token_id(&self, token_ids: Vec<TokenId>) -> Vec<Option<MtTokenMetadata>> {
        token_ids.iter().map(|id| self.tokens.get(id).map(|t| t.token.clone())).collect()
    }

    pub fn mt_metadata_base_by_token_id(&self, token_ids: Vec<TokenId>) -> Vec<Option<MtBaseTokenMetadata>> {
        token_ids.iter().map(|id| self.tokens.get(id).map(|t| t.base.clone())).collect()
    }

    /// Every registered token id (not part of NEP-245; handy for explorers and the game).
    pub fn mt_tokens(&self) -> Vec<TokenId> {
        self.tokens.keys().cloned().collect()
    }

    // ------------------------------------------------------------------ internals

    fn assert_token(&self, token_id: &TokenId) {
        require!(self.tokens.contains_key(token_id), "Unknown token id");
    }

    fn internal_balance(&self, token_id: &str, account_id: &AccountId) -> u128 {
        self.balances.get(&balance_key(token_id, account_id)).copied().unwrap_or(0)
    }

    fn internal_set_balance(&mut self, token_id: &str, account_id: &AccountId, value: u128) {
        let key = balance_key(token_id, account_id);
        if value == 0 {
            self.balances.remove(&key);
        } else {
            self.balances.insert(key, value);
        }
    }

    fn internal_transfer(
        &mut self,
        sender_id: &AccountId,
        receiver_id: &AccountId,
        token_ids: &[TokenId],
        amounts: &[U128],
        memo: Option<String>,
    ) {
        require!(sender_id != receiver_id, "Sender and receiver must differ");
        require!(!token_ids.is_empty() && token_ids.len() <= MAX_BATCH, "1-32 token ids per transfer");
        require!(token_ids.len() == amounts.len(), "token_ids and amounts differ in length");
        for (token_id, amount) in token_ids.iter().zip(amounts) {
            self.assert_token(token_id);
            require!(amount.0 > 0, "Amount must be positive");
            let from = self.internal_balance(token_id, sender_id);
            require!(from >= amount.0, "Insufficient balance");
            self.internal_set_balance(token_id, sender_id, from - amount.0);
            let to = self.internal_balance(token_id, receiver_id);
            self.internal_set_balance(token_id, receiver_id, to.checked_add(amount.0).expect("Balance overflow"));
        }
        emit(
            "mt_transfer",
            json!({ "old_owner_id": sender_id, "new_owner_id": receiver_id, "token_ids": token_ids,
                "amounts": amounts.iter().map(|a| a.0.to_string()).collect::<Vec<_>>(), "memo": memo }),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use near_sdk::test_utils::{accounts, VMContextBuilder};
    use near_sdk::{testing_env, NearToken};

    fn base(name: &str, id: &str) -> MtBaseTokenMetadata {
        MtBaseTokenMetadata {
            name: name.to_string(),
            id: id.to_string(),
            symbol: None,
            icon: None,
            decimals: Some("0".to_string()),
            base_uri: None,
            reference: None,
            copies: None,
            reference_hash: None,
        }
    }

    fn context(predecessor: AccountId) -> VMContextBuilder {
        let mut builder = VMContextBuilder::new();
        builder.current_account_id(accounts(0)).predecessor_account_id(predecessor).prepaid_gas(Gas::from_tgas(300));
        builder
    }

    /// accounts(1) = relayer/owner, accounts(2) = courier, accounts(3) = merchant, accounts(4) = stranger.
    fn setup() -> CampCommodities {
        testing_env!(context(accounts(1)).build());
        let mut c = CampCommodities::new(accounts(1), None, None);
        c.register_token("1".to_string(), base("Medkit", "1"), None);
        c.register_token("3".to_string(), base("Pizza Delivery Contract", "3"), None);
        c
    }

    #[test]
    fn mint_tracks_balance_and_supply() {
        let mut c = setup();
        c.mt_mint(accounts(2), "1".to_string(), U128(5), Some("haul:run-1".to_string()));
        assert_eq!(c.mt_balance_of(accounts(2), "1".to_string()), U128(5));
        assert_eq!(c.mt_supply("1".to_string()), Some(U128(5)));
        assert_eq!(c.mt_batch_balance_of(accounts(2), vec!["1".into(), "3".into()]), vec![U128(5), U128(0)]);
        assert_eq!(c.mt_token(vec!["1".into(), "9".into()]).iter().filter(|t| t.is_some()).count(), 1);
    }

    #[test]
    #[should_panic(expected = "Operator only")]
    fn strangers_cannot_mint() {
        let mut c = setup();
        testing_env!(context(accounts(4)).build());
        c.mt_mint(accounts(4), "1".to_string(), U128(1), None);
    }

    #[test]
    fn relayed_transfer_is_idempotent() {
        let mut c = setup();
        c.mt_mint(accounts(2), "1".to_string(), U128(5), None);
        let first = c.relayed_transfer("intent-1".into(), accounts(2), accounts(3), vec!["1".into()], vec![U128(5)], Some("sell".into()));
        let again = c.relayed_transfer("intent-1".into(), accounts(2), accounts(3), vec!["1".into()], vec![U128(5)], None);
        assert!(first);
        assert!(!again, "a retried intent must not move tokens twice");
        assert_eq!(c.mt_balance_of(accounts(2), "1".to_string()), U128(0));
        assert_eq!(c.mt_balance_of(accounts(3), "1".to_string()), U128(5));
        assert!(c.intent_executed("intent-1".into()));
    }

    #[test]
    #[should_panic(expected = "Insufficient balance")]
    fn relayed_transfer_needs_balance() {
        let mut c = setup();
        c.relayed_transfer("intent-2".into(), accounts(2), accounts(3), vec!["1".into()], vec![U128(1)], None);
    }

    #[test]
    fn courier_can_transfer_directly_with_one_yocto() {
        let mut c = setup();
        c.mt_mint(accounts(2), "3".to_string(), U128(2), None);
        testing_env!(context(accounts(2)).attached_deposit(NearToken::from_yoctonear(1)).build());
        c.mt_transfer(accounts(3), "3".to_string(), U128(1), None, None);
        assert_eq!(c.mt_balance_of(accounts(2), "3".to_string()), U128(1));
        assert_eq!(c.mt_balance_of(accounts(3), "3".to_string()), U128(1));
    }

    #[test]
    #[should_panic(expected = "Requires attached deposit of exactly 1 yoctoNEAR")]
    fn direct_transfer_requires_one_yocto() {
        let mut c = setup();
        c.mt_mint(accounts(2), "3".to_string(), U128(2), None);
        testing_env!(context(accounts(2)).build());
        c.mt_transfer(accounts(3), "3".to_string(), U128(1), None, None);
    }

    #[test]
    fn burn_reduces_supply() {
        let mut c = setup();
        c.mt_mint(accounts(3), "3".to_string(), U128(2), None);
        c.mt_burn(accounts(3), "3".to_string(), U128(1), Some("redeemed".into()));
        assert_eq!(c.mt_supply("3".to_string()), Some(U128(1)));
        assert_eq!(c.mt_balance_of(accounts(3), "3".to_string()), U128(1));
    }

    #[test]
    fn resolve_refunds_unused() {
        let mut c = setup();
        c.mt_mint(accounts(3), "1".to_string(), U128(4), None);
        // Pretend 4 were sent courier -> merchant and the merchant only used 1.
        testing_env!(context(accounts(0)).build());
        let used = c.mt_resolve_transfer(vec![accounts(2)], accounts(3), vec!["1".into()], vec![U128(4)], Ok(vec![U128(3)]));
        assert_eq!(used, vec![U128(1)]);
        assert_eq!(c.mt_balance_of(accounts(2), "1".to_string()), U128(3));
        assert_eq!(c.mt_balance_of(accounts(3), "1".to_string()), U128(1));
    }

    #[test]
    fn metadata_round_trips() {
        let c = setup();
        assert_eq!(c.mt_metadata_contract().spec, "mt-1.0.0");
        let all = c.mt_metadata_token_all(vec!["1".into()]);
        assert_eq!(all[0].as_ref().unwrap().base.name, "Medkit");
        assert_eq!(c.mt_tokens().len(), 2);
    }

    #[test]
    fn operators_can_be_managed_by_owner() {
        let mut c = setup();
        c.add_operator(accounts(4));
        assert!(c.is_operator(accounts(4)));
        c.remove_operator(accounts(4));
        assert!(!c.is_operator(accounts(4)));
        assert!(c.is_operator(accounts(1)));
    }
}
